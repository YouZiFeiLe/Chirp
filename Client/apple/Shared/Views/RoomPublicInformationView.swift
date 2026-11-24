import SwiftUI

struct RoomPublicInformationView: View {
    @Environment(\.roomIdentity) private var identity
    @ObservedObject var call: CallController
    let room: RoomOverview

    var body: some View {
        RoomPublicInformationButton(room: room, information: isCurrent ? call.roomPublicInformation : nil,
                                    trust: isCurrent ? identity?.trust : nil, joined: isCurrent && call.hasSession,
                                    locallyReady: isCurrent && call.isConnected)
    }
    private var isCurrent: Bool { call.currentRoomID == room.roomID }
}

struct RoomPublicInformationButton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.roomNeedsVerification) private var needsVerification
    let room: RoomOverview
    let information: RoomPublicInformation?
    let trust: RoomIdentity.VoiceTrust?
    var joined = true
    var locallyReady = true
    @State private var isPresented = false

    var body: some View {
        let ink = needsVerification ? ChirpTheme.roomVerificationInk : ChirpTheme.accent
        Button { isPresented = true } label: {
            MessageLabel("房间公共信息", systemImage: "info.circle")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(ink.opacity(0.07), in: .capsule)
                .overlay { Capsule().strokeBorder(ink.opacity(0.16)) }
                .roomActionTarget().contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("room-information")
        #if os(macOS)
        .messageHelp("房间公共信息")
        .keyboardShortcut("i", modifiers: [.command, .option])
        .popover(isPresented: $isPresented) { panel }
        #else
        .sheet(isPresented: $isPresented) { panel }
        #endif
    }

    private var panel: some View {
        RoomPublicInformationContent(room: room, information: information, trust: trust,
                                     joined: joined, locallyReady: locallyReady)
            .dynamicTypeSize(dynamicTypeSize)
    }
}

private struct RoomPublicInformationContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let room: RoomOverview
    let information: RoomPublicInformation?
    let trust: RoomIdentity.VoiceTrust?
    let joined: Bool
    let locallyReady: Bool
    @State private var securityExpanded = false
    @State private var rulesExpanded = false
    @State private var protocolExpanded = false
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    private var fittedHeight: CGFloat { ceil(headerHeight + contentHeight + 1) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                MessageLabel("房间公共信息", systemImage: "info.circle")
                    .font(.headline).foregroundStyle(ChirpTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button { dismiss() } label: { MessageText("完成").roomActionTarget() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("close-room-information")
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            #if os(iOS)
            .padding(.top, 6)
            #endif
            .background(ChirpTheme.surface)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            Divider()
            ScrollView {
                Group {
                    if joined {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let now = ContinuousClock.now
                            sections(now: now, fresh: information?.isFresh(at: now) == true)
                        }
                    } else {
                        sections(now: .now, fresh: false)
                    }
                }
                .padding(20)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        #if os(macOS)
        .frame(minWidth: 300, idealWidth: 400, maxWidth: 440)
        .frame(height: contentHeight > 0 ? min(fittedHeight, 560) : 360)
        #else
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] :
                                [contentHeight > 0 ? .height(fittedHeight) : .medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .background(ChirpTheme.canvas).tint(ChirpTheme.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-public-information")
        .logScreen("roomInformation")
        .onChange(of: rulesExpanded) { ClientLog.shared.record(.navigation, rulesExpanded ? "expandRoomRules" : "collapseRoomRules") }
        .onChange(of: protocolExpanded) { ClientLog.shared.record(.navigation, protocolExpanded ? "expandProtocol" : "collapseProtocol") }
    }

    private var info: GroupRoomInformation? { information?.information }
    private var waitingForIdentity: Bool { trust == .pending || trust == .rebuilding }

    private func sections(now: ContinuousClock.Instant, fresh: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            summary(now: now, fresh: fresh)
            details(fresh: fresh)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(now: ContinuousClock.Instant, fresh: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                MessageLabel(statusTitle(fresh: fresh), systemImage: waitingForIdentity ? "exclamationmark.shield" : "lock.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(trust == .pending ? ChirpTheme.roomVerificationInk : trust == .stopped ? ChirpTheme.warning : ChirpTheme.ink)
                    .accessibilityIdentifier("room-public-status")
                MessageText(statusDetail(fresh: fresh)).font(.caption).foregroundStyle(ChirpTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if joined {
                VStack(spacing: 12) {
                    RoomDetailRow(title: info?.lastRotationAtMS == nil ? "本次安全连接建立" : fresh ? "上次全员换钥完成" : "上次确认的换钥") {
                        if !waitingForIdentity, let date = information?.eventDate(info?.lastRotationAtMS ?? info?.establishedAtMS) {
                            Text(date, format: .dateTime.hour().minute().second()).monospacedDigit()
                        } else { MessageText("尚未建立") }
                    }
                    .accessibilityIdentifier("room-last-rotation")
                    RoomDetailRow(title: "下次计划换钥") {
                        MessageText(nextRotation(fresh: fresh, now: now)).monospacedDigit()
                    }.accessibilityIdentifier("room-next-rotation")
                }
                .padding(14).background(ChirpTheme.surfaceSubtle.opacity(0.65), in: .rect(cornerRadius: 14))
            }
            if joined {
                MessageLabel(fresh ? "已同步当前房间状态" : "房间状态暂时无法同步", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chirpSurface(padding: 18)
    }

    private func details(fresh: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if joined {
                RoomInformationGroup(title: "加密与换钥详情", expanded: $securityExpanded) {
                    RoomDetailRow(title: "加密覆盖") { MessageText("语音 · 文字 · 附件") }
                        .accessibilityIdentifier("room-encryption-coverage")
                    if let info, !waitingForIdentity {
                        RoomDetailRow(title: "当前轮次") {
                            MessageText(fresh ? "第 \(String(info.keyEpoch + 1)) 轮" : "等待同步")
                        }
                        RoomDetailRow(title: "当前进度") { MessageText(fresh ? info.progress : "等待同步") }
                        if fresh, info.rotationPhase != nil {
                            RoomDetailRow(title: "已确认设备") {
                                Text(verbatim: "\(info.confirmedMembers) / \(info.memberCount)").monospacedDigit()
                            }
                            RoomDetailRow(title: "已切换设备") {
                                Text(verbatim: "\(info.activatedMembers) / \(info.memberCount)").monospacedDigit()
                            }
                        }
                        RoomDetailRow(title: "最近更新原因") { MessageText(info.reason) }
                        RoomDetailRow(title: "例行计划间隔") {
                            let number = Int(info.rotationIntervalMS / 1_000)
                            MessageText("\(number) 秒")
                        }
                        if let date = information?.eventDate(info.lastRotationAtMS ?? info.establishedAtMS) {
                            RoomDetailRow(title: "上次确认时间") {
                                Text(date, format: .dateTime.year().month().day().hour().minute().second())
                            }
                        }
                    } else { MessageText("完成设备互认后建立安全连接。") }
                    MessageText("成员变化或重连可能提前重建加密连接。")
                        .font(.caption).foregroundStyle(ChirpTheme.secondary)
                }
            }
            RoomInformationGroup(title: "房间规则", expanded: $rulesExpanded) {
                RoomDetailRow(title: "加入方式") { MessageText(room.passwordRequired ? "需要房间密码" : "无需房间密码") }
                RoomDetailRow(title: "人数上限") {
                    if room.maxParticipants > 0 { Text(room.maxParticipants.formatted()) }
                    else { MessageText("人数不限") }
                }
                RoomDetailRow(title: "入房麦克风") { MessageText("默认静音") }
            }
            if joined {
                RoomInformationGroup(title: "协议详情", expanded: $protocolExpanded) {
                    RoomDetailRow(title: "加密协议") { Text(verbatim: "MLS") }
                    RoomDetailRow(title: "Chirp 协议版本") { Text(verbatim: "V5") }
                }
            }
        }
    }

    private func statusTitle(fresh: Bool) -> LocalizedMessage {
        guard joined else { return "加入后查看安全状态" }
        switch trust {
        case .pending: return "等待设备互认"
        case .rebuilding: return "正在更新安全连接"
        case .stopped: return "语音已停止"
        default: break
        }
        guard fresh else { return "房间状态待同步" }
        guard locallyReady else { return "正在建立安全连接" }
        if info?.rotationPhase != nil { return "正在更新加密密钥" }
        return trust == .solo ? "等朋友加入" : "端到端加密已就绪"
    }

    private func statusDetail(fresh: Bool) -> LocalizedMessage {
        guard joined else { return "加入房间后，可以查看本次连接与换钥进度。" }
        switch trust {
        case .pending: return "完成设备互认后建立安全连接。"
        case .rebuilding: return "全员核验完成，正在建立新的加密密钥，保持静音。"
        case .stopped: return "语音已停止，请检查授权状态或重新核验。"
        default: break
        }
        guard fresh else { return "暂时无法确认最新进度，正在重新同步。" }
        guard locallyReady else { return "全员核验完成，正在建立新的加密密钥，保持静音。" }
        return trust == .solo ? "这里暂时只有你，朋友加入后就能开聊。" : "当前所有参与设备已互认，可信加密语音已就绪。"
    }

    private func nextRotation(fresh: Bool, now: ContinuousClock.Instant) -> LocalizedMessage {
        guard !waitingForIdentity else { return "互认完成后安排" }
        guard fresh, trust != .stopped else { return "暂时未知" }
        if info?.rotationPhase == "switching" { return "等待全员完成" }
        guard let number = information?.nextRotationSeconds(at: now) else { return "尚未安排" }
        return number == 0 ? "正在更新" : "约 \(number) 秒后"
    }
}

struct RoomInformationGroup<Content: View>: View {
    let title: LocalizedMessage
    @Binding var expanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(ChirpTheme.border)
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12, content: content).padding(.top, 12).padding(.bottom, 4)
            } label: {
                MessageText(title).font(.subheadline.weight(.medium)).frame(minHeight: 44, alignment: .leading)
            }
            .tint(ChirpTheme.accent)
        }
    }
}

struct RoomDetailRow<Content: View>: View {
    let title: LocalizedMessage
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                MessageText(title).foregroundStyle(ChirpTheme.secondary).fixedSize()
                Spacer(minLength: 0)
                content().foregroundStyle(ChirpTheme.ink).fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                MessageText(title).foregroundStyle(ChirpTheme.secondary)
                content().foregroundStyle(ChirpTheme.ink).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
