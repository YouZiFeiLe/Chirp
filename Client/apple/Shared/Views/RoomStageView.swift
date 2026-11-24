import SwiftUI

struct RoomDirectoryCard: View {
    @Environment(\.locale) private var locale
    let room: RoomOverview
    let isFresh: Bool
    var isCurrent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                RoomEmblem(size: 46)
                VStack(alignment: .leading, spacing: 5) {
                    Text(room.localizedDisplayName(in: locale))
                        .font(.system(.headline, design: .rounded)).foregroundStyle(ChirpTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    MessageLabel(room.passwordRequired ? "密码房间" : "语音房间",
                                 systemImage: room.passwordRequired ? "lock" : "waveform")
                        .font(.caption).foregroundStyle(ChirpTheme.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isCurrent ? "waveform" : "arrow.up.right")
                    .font(.subheadline.weight(.medium)).foregroundStyle(ChirpTheme.accent)
                    .frame(width: 32, height: 32)
                    .background(ChirpTheme.surfaceSubtle, in: .circle)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 10) {
                if let members = room.participants, !members.isEmpty {
                    HStack(spacing: -7) {
                        ForEach(Array(members.prefix(3))) { member in
                            IdentityAvatar(name: member.displayName, identity: member.id, size: 26)
                                .overlay { Circle().strokeBorder(ChirpTheme.surface, lineWidth: 2) }
                        }
                    }
                    .accessibilityHidden(true)
                }
                MessageText(isCurrent ? "正在通话" : room.presenceDescription(isFresh: isFresh))
                    .font(.caption.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? ChirpTheme.accent : ChirpTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "phone.fill").font(.caption).foregroundStyle(ChirpTheme.accent)
                        .accessibilityHidden(true)
                }
            }
        }
        .chirpSurface(padding: 20)
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: ChirpTheme.Radius.card)
                    .strokeBorder(ChirpTheme.accent, lineWidth: 1.5)
            }
        }
        .contentShape(.rect(cornerRadius: ChirpTheme.Radius.card))
        .accessibilityElement(children: .combine)
        .messageAccessibilityValue(room.passwordRequired ? "密码房间" : "无密码房间")
    }
}

extension RoomOverview {
    func presenceDescription(isFresh: Bool) -> LocalizedMessage {
        guard isFresh, isAvailable else { return "在线状态待同步" }
        let count = participants?.count ?? 0
        return count == 0 ? "房间内暂无用户" : "\(count) 位朋友在这里"
    }
}

struct RoomHeader<Accessory: View>: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.roomNeedsVerification) private var needsVerification
    let room: RoomOverview
    var status: LocalizedMessage? = nil
    let accessory: Accessory?
    var compact = false

    var body: some View {
        let heading = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) :
                                                    AnyLayout(HStackLayout(spacing: 8))
        VStack(alignment: .leading, spacing: compact ? 12 : 20) {
            heading {
                ChirpEyebrow(title: "语音房间")
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                if let accessory {
                    accessory.layoutPriority(1)
                } else {
                    Image(systemName: "waveform")
                        .font(.title2.weight(.light)).foregroundStyle(ChirpTheme.accent)
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(room.localizedDisplayName(in: locale))
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .tracking(-0.8)
                    .foregroundStyle(ChirpTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: room.displayDescription(in: locale))
                    .font(.subheadline).foregroundStyle(ChirpTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status {
                    MessageText(status).font(.caption).foregroundStyle(ChirpTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { badges }
                VStack(alignment: .leading, spacing: 8) { badges }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, compact ? 16 : 24)
        .background(LinearGradient(colors: needsVerification ? [ChirpTheme.roomVerificationSurface, ChirpTheme.roomVerificationCanvas] :
                                      [ChirpTheme.hero, ChirpTheme.surfaceSubtle.opacity(0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: ChirpTheme.Radius.hero))
    }

    @ViewBuilder private var badges: some View {
        ChirpBadge(title: "端到端加密保护", systemImage: "lock.shield", emphasized: !needsVerification)
        ChirpBadge(title: room.passwordRequired ? "密码房间" : "人数不限",
                   systemImage: room.passwordRequired ? "lock" : "person.2")
    }
}

extension RoomHeader where Accessory == EmptyView {
    init(room: RoomOverview, status: LocalizedMessage? = nil) {
        self.init(room: room, status: status, accessory: nil)
    }
}

struct RoomEmptyState: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: LocalizedMessage
    let message: LocalizedMessage
    var isLoading = false
    var compact = false

    @ViewBuilder
    var body: some View {
        if compact {
            inlineContent(waveSize: 80, spacing: 24)
                .chirpSurface(padding: 20)
        } else {
            #if os(iOS)
            ViewThatFits(in: .vertical) {
                centeredContent(waveSize: 148, spacing: 14, padding: 6)
                centeredContent(waveSize: 120, spacing: 12, padding: 4)
                centeredContent(waveSize: 96, spacing: 10, padding: 2)
                if typeSize.isAccessibilitySize {
                    explanation(leading: true)
                } else {
                    inlineContent(waveSize: 84, spacing: 16)
                }
            }
            .frame(maxHeight: .infinity)
            #else
            centeredContent(waveSize: 148, spacing: 18, padding: 28)
            #endif
        }
    }

    private func centeredContent(waveSize: CGFloat, spacing: CGFloat, padding: CGFloat) -> some View {
        VStack(spacing: spacing) {
            QuietWave(size: waveSize)
            explanation(leading: false)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, padding)
    }

    private func inlineContent(waveSize: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            QuietWave(size: waveSize)
            explanation(leading: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func explanation(leading: Bool) -> some View {
        VStack(alignment: leading ? .leading : .center, spacing: 10) {
            MessageText(title).font(.title3.weight(.semibold)).foregroundStyle(ChirpTheme.ink)
            MessageText(message).font(.subheadline).foregroundStyle(ChirpTheme.secondary)
                .frame(maxWidth: leading ? 420 : 300, alignment: leading ? .leading : .center)
            if isLoading { ProgressView().controlSize(.small).tint(ChirpTheme.accent) }
        }
        .multilineTextAlignment(leading ? .leading : .center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct RoomMembersSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.roomIdentity) private var roomIdentity
    @ObservedObject var call: CallController
    let room: RoomOverview
    var isFresh = true
    @State private var audioMember: CallMember?
    @State private var pendingVerificationID: String?

    private var isCurrent: Bool { call.currentRoomID == room.roomID }
    private var count: LocalizedMessage {
        if isCurrent { return "\(call.members.count) 位成员" }
        return isFresh && room.isAvailable ? "\(room.participants?.count ?? 0) 位成员" : "等待同步"
    }
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 132), spacing: 12)]
    }
    private var compactEmptyState: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        let pendingIDs = isCurrent ? Set(roomIdentity?.peersNeedingVerification.map(\.identity) ?? []) : []
        VStack(alignment: .leading, spacing: 20) {
            ChirpSectionHeading(title: "在这里", detail: count)
            if isCurrent && !call.members.isEmpty {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(call.members) { member in
                        if call.canAdjustVolume(for: member.id) {
                            Button { audioMember = member } label: {
                                MemberCard(member: member, canAdjustAudio: true, allowsIdentityAction: false,
                                           requiresVerification: pendingIDs.contains(member.id))
                            }
                            .buttonStyle(.plain)
                            .messageAccessibilityHint("查看成员信息与调整本机音量")
                            .accessibilityIdentifier("member-information-\(member.id)")
                            .contextMenu {
                                Button { audioMember = member } label: { MessageText("成员信息与音量") }
                            }
                        } else {
                            MemberCard(member: member)
                        }
                    }
                }
            } else if !isCurrent, let members = room.participants, !members.isEmpty {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(members) { member in DirectoryMemberCard(member: member) }
                }
            } else {
                RoomEmptyState(
                    title: isCurrent && (call.isBusy || call.hasSession) ? "正在为你连接" : !isFresh || !room.isAvailable ? "等待房间状态" : "林间还很安静",
                    message: isCurrent ? call.status : !isFresh || !room.isAvailable ? "暂时无法取得最新成员，稍后会自动更新。" : "房间里暂时还没有人。\n喊上朋友，或者先开麦试个音。",
                    isLoading: isCurrent && (call.isBusy || call.hasSession), compact: compactEmptyState)
            }
            if !isCurrent && !(room.participants?.isEmpty ?? true) {
                MessageText(isFresh ? "加入后即可听见彼此。" : "当前显示上次同步的成员。")
                    .font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
        }
        #if os(iOS)
        .sheet(item: $audioMember, onDismiss: presentPendingVerification) { member in
            memberInformation(member)
        }
        #else
        .popover(item: $audioMember) { member in
            memberInformation(member).onDisappear(perform: presentPendingVerification)
        }
        #endif
        .onChange(of: call.currentRoomID) {
            pendingVerificationID = nil
            audioMember = nil
        }
    }

    private func memberInformation(_ member: CallMember) -> some View {
        MemberInformationView(call: call, memberID: member.id, fallbackName: member.name,
                              requestVerification: { pendingVerificationID = $0 })
            .dynamicTypeSize(dynamicTypeSize)
    }

    private func presentPendingVerification() {
        defer { pendingVerificationID = nil }
        guard call.currentRoomID == room.roomID, let id = pendingVerificationID,
              let roomIdentity, let peer = roomIdentity.remotePeer(for: id) else { return }
        roomIdentity.presentVerification(peer)
    }
}

struct RoomAudioSummary: View {
    let title: LocalizedMessage
    let detail: LocalizedMessage
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.body).foregroundStyle(ChirpTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(ChirpTheme.surfaceSubtle, in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    MessageText(title).font(.subheadline.weight(.medium)).foregroundStyle(ChirpTheme.ink)
                    MessageText(detail).font(.caption).foregroundStyle(ChirpTheme.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(ChirpTheme.secondary)
            }
            .chirpSurface(padding: 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityIdentifier("audio-preset-settings")
    }
}
