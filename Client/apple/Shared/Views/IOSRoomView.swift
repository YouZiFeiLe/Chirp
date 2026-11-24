#if os(iOS)
import AVFoundation
import SwiftUI

struct IOSRoomView: View {
    @Environment(\.locale) private var locale
    @Environment(\.roomIdentity) private var roomIdentity
    @ObservedObject var call: CallController
    @ObservedObject var directory: RoomDirectory
    let roomID: String
    let showAudioSettings: () -> Void
    @State private var section = RoomSection.members
    @State private var lastReadMessageID: String?

    private enum RoomSection { case members, chat }
    private var room: RoomOverview { directory.room(roomID) }
    private var isCurrent: Bool { call.currentRoomID == roomID }
    private var chatAvailable: Bool { call.showsChat(in: roomID) }
    private var unreadCount: Int { section == .chat ? 0 : call.chat.unreadCount(after: lastReadMessageID) }

    var body: some View {
        VStack(spacing: 0) {
            if chatAvailable {
                Picker("房间内容", selection: $section) {
                    MessageText("成员").tag(RoomSection.members)
                    MessageText(unreadCount > 0 ? "聊天 · \(unreadCount)" : "聊天").tag(RoomSection.chat)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .accessibilityIdentifier("room-content-picker")
            }
            if chatAvailable && section == .chat {
                identityStatus.padding(.horizontal, 24).padding(.bottom, 12)
                RoomChatPanel(call: call)
            } else {
                roomContent
            }
        }
        .roomVerificationStatus(call: call, roomID: roomID, identity: roomIdentity)
        .navigationTitle(room.localizedDisplayName(in: locale))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: showAudioSettings) { MessageLabel("声音设置", systemImage: "slider.horizontal.3") }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("room-audio-settings")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if call.hasSession && !isCurrent {
                    MessageText("当前通话：\(call.roomDisplayName)").font(.caption).foregroundStyle(ChirpTheme.secondary)
                } else if call.isBusy || call.hasSession || call.preparingRoomID != nil {
                    ConnectionStatusLabel(call: call)
                } else {
                    MessageLabel("以静音状态加入，准备好后再开麦", systemImage: "mic.slash")
                        .font(.caption).foregroundStyle(ChirpTheme.secondary)
                }
                CallControlsView(call: call, room: room)
            }
            .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 16)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("room-call-controls")
        }
        .logScreen("room")
        .onChange(of: chatAvailable) { _, available in
            if !available { section = .members; lastReadMessageID = nil }
        }
        .onChange(of: section) { _, value in
            ClientLog.shared.record(.navigation, value == .chat ? "roomChat" : "roomMembers")
            if value == .chat { lastReadMessageID = call.chat.messages.last?.id }
        }
        .onChange(of: call.chat.messages.last?.id) { _, id in
            if section == .chat { lastReadMessageID = id }
        }
    }

    @ViewBuilder
    private var identityStatus: some View {
        if isCurrent, let roomIdentity, roomIdentity.trust != .pending {
            RoomIdentityStatusCard(trust: roomIdentity.trust)
        }
    }

    private var roomContent: some View {
        GeometryReader { viewport in
            ScrollView {
                roomSections(viewportHeight: viewport.size.height)
            }
        }
    }

    private func roomSections(viewportHeight: CGFloat) -> some View {
        let isEmpty = !isCurrent && (room.participants?.isEmpty ?? true)
        let tight = isEmpty && viewportHeight < 560
        let inset: CGFloat = tight ? 12 : 24
        let spacing: CGFloat = viewportHeight < 450 ? 8 : inset
        let column = isEmpty
            ? AnyLayout(EmptyRoomColumn(height: viewportHeight - 2 * inset, spacing: spacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
        return column {
            RoomHeader(room: room, status: isCurrent ? call.roomSummary : nil,
                       accessory: RoomPublicInformationView(call: call, room: room), compact: tight)
            if let message = call.errorMessage { CallNotice(message: message) }
            RoomMembersSection(call: call, room: room, isFresh: directory.isFresh)
                .layoutPriority(isEmpty ? -1 : 0)
            if let message = directory.syncMessage {
                MessageText(message).font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
            RoomAudioSummary(title: "声音设置", detail: call.audioPreset.shortTitle,
                             action: showAudioSettings)
                .fixedSize(horizontal: false, vertical: true)
            if isCurrent && call.hasSession && roomIdentity?.trust != .pending {
                MessageLabel(call.encryptionStatus, systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(ChirpTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 24)
        .padding(.vertical, inset)
        .frame(maxWidth: .infinity)
    }
}

// Scroll views offer unlimited height. Measure the other rows at their natural
// heights and give the members section the actual space above the call controls.
private struct EmptyRoomColumn: Layout {
    let height: CGFloat
    let spacing: CGFloat

    private func rows(width: CGFloat?, subviews: Subviews) -> [(proposal: ProposedViewSize, size: CGSize)] {
        let natural = ProposedViewSize(width: width, height: nil)
        var rows = subviews.map { (proposal: natural, size: $0.sizeThatFits(natural)) }
        if let members = subviews.indices.first(where: { subviews[$0].priority < 0 }) {
            let others = rows.reduce(0) { $0 + $1.size.height } - rows[members].size.height
            let gaps = spacing * CGFloat(rows.count - 1)
            let available = ProposedViewSize(width: width, height: max(0, height - others - gaps))
            rows[members] = (available, subviews[members].sizeThatFits(available))
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.size.width).max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.size.height } + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (view, row) in zip(subviews, rows(width: bounds.width, subviews: subviews)) {
            view.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: row.proposal)
            y += row.size.height + spacing
        }
    }
}

struct RoomAudioOutputButton: View {
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var optionIconWidth: CGFloat = 24
    @ObservedObject var audio: CallAudioController
    @State private var showsOutputs = false
    @State private var failure: ClientFailure?
    @State private var hasWirelessOutputs = false

    private var devices: CallAudioSnapshot { audio.devices }
    private var quickOutput: CallAudioOutput? { hasWirelessOutputs ? nil : devices.alternateBuiltInOutput }
    private var needsRouteDetection: Bool { scenePhase == .active && devices.alternateBuiltInOutput != nil }
    private var actionTitle: LocalizedMessage {
        switch quickOutput {
        case .speaker: "切到扬声器"
        case .receiver: "切到听筒"
        default: "输出设备"
        }
    }
    private var outputSymbol: String {
        switch devices.route {
        case .bluetooth, .wired: "headphones"
        case .speaker: "speaker.wave.2.fill"
        case .receiver: "iphone"
        default: "airplayaudio"
        }
    }

    var body: some View {
        Button {
            if let next = quickOutput {
                change { try await audio.preferOutput(next) }
            } else {
                showOutputs()
            }
        } label: {
            if let next = quickOutput {
                MessageLabel(actionTitle, systemImage: next == .speaker ? "speaker.wave.2.fill" : "iphone")
            } else {
                Label {
                    MessageText(devices.outputTitle)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .minimumScaleFactor(0.9)
                } icon: {
                    HStack(spacing: 3) {
                        Image(systemName: outputSymbol)
                        Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true)
                    }
                }
            }
        }
        .buttonStyle(.glass)
        .disabled(!audio.isAvailable || audio.isChangingDevice)
        .messageAccessibilityLabel(actionTitle)
        .messageAccessibilityValue(devices.outputTitle)
        .messageAccessibilityHint("切换音频路由")
        .accessibilityIdentifier("room-audio-output")
        .contextMenu { Button("输出设备", action: showOutputs) }
        .task { await audio.refresh() }
        .task(id: needsRouteDetection) { await detectWirelessOutputs() }
        .sheet(isPresented: $showsOutputs) { outputSheet }
    }

    private var outputSheet: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent { MessageText(devices.outputTitle) } label: { MessageText("当前输出") }
                    if let failure { FailureText(failure).foregroundStyle(ChirpTheme.danger) }
                }
                Section {
                    if devices.supportsReceiver {
                        option("听筒", symbol: "iphone", selected: devices.route == .receiver) {
                            try await audio.preferOutput(.receiver)
                        }
                    }
                    option("扬声器", symbol: "speaker.wave.2.fill", selected: devices.route == .speaker) {
                        try await audio.preferOutput(.speaker)
                    }
                    ForEach(devices.headsetInputs) { input in
                        option("\(input.name)", symbol: "headphones",
                               selected: devices.route == input.route && devices.activeInputID == input.id) {
                            try await audio.selectInput(input.id)
                        }
                    }
                }
                .labelReservedIconWidth(optionIconWidth)
                Section {
                    Button("系统路由") { change { try await audio.preferOutput(.system) } }
                    HStack {
                        MessageText("耳机与蓝牙路由")
                        Spacer()
                        CallAudioRoutePicker().frame(width: 44, height: 44)
                    }
                }
            }
            .disabled(audio.isChangingDevice)
            .labelStyle(.titleAndIcon)
            .buttonStyle(.automatic)
            .messageNavigationTitle("输出设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { showsOutputs = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func detectWirelessOutputs() async {
        // Playback-only accessories need not appear in AVAudioSession.availableInputs.
        guard needsRouteDetection else { hasWirelessOutputs = false; return }
        let detector = AVRouteDetector()
        let changes = NotificationCenter.default.notifications(
            named: .AVRouteDetectorMultipleRoutesDetectedDidChange, object: detector)
        detector.isRouteDetectionEnabled = true
        defer { detector.isRouteDetectionEnabled = false }
        hasWirelessOutputs = detector.multipleRoutesDetected
        for await _ in changes { hasWirelessOutputs = detector.multipleRoutesDetected }
    }

    private func option(_ title: LocalizedMessage, symbol: String, selected: Bool,
                        action: @escaping @MainActor () async throws -> Void) -> some View {
        Button {
            change(action)
        } label: {
            HStack {
                MessageLabel(title, systemImage: symbol)
                Spacer()
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func showOutputs() {
        failure = nil
        showsOutputs = true
    }

    private func change(_ action: @escaping @MainActor () async throws -> Void) {
        failure = nil
        Task {
            do {
                try await action()
                showsOutputs = false
            } catch is CancellationError {
                return
            } catch {
                failure = ClientFailure.capture(error, fallback: .audioDeviceChangeFailed)
                showsOutputs = true
            }
        }
    }
}
#endif
