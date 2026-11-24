import SwiftUI

extension EnvironmentValues {
    @Entry var roomNeedsVerification = false
}

extension View {
    @MainActor
    func roomVerificationStatus(call: CallController, roomID: String, identity: RoomIdentity?) -> some View {
        let isPending = call.currentRoomID == roomID && identity?.trust == .pending
        let targets: [MemberInfo]
        if isPending, let identity {
            let names = Dictionary(call.members.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            targets = identity.peersNeedingVerification.map { peer in
                MemberInfo(id: peer.identity, displayName: names[peer.identity] ?? peer.name)
            }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        } else {
            targets = []
        }
        return roomVerificationStatus(isPending: isPending, targets: targets) { entry in
            guard call.currentRoomID == roomID else { return }
            identity?.presentPendingVerification(for: entry)
        }
    }

    func roomVerificationStatus(isPending: Bool, targets: [MemberInfo], verify: @escaping (String) -> Void) -> some View {
        VStack(spacing: 0) {
            if isPending {
                RoomVerificationBanner(targets: targets, verify: verify)
                    .frame(maxWidth: 880)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(ChirpTheme.roomVerificationCanvas)
            }
            self
        }
        .background(isPending ? ChirpTheme.roomVerificationCanvas : ChirpTheme.canvas)
        .environment(\.roomNeedsVerification, isPending)
    }
}

private struct RoomVerificationBanner: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let targets: [MemberInfo]
    let verify: (String) -> Void

    var body: some View {
        Group {
            #if os(macOS)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    summary
                    action.fixedSize(horizontal: true, vertical: false)
                }
                stackedContent
            }
            #else
            stackedContent
            #endif
        }
        .padding(14)
        .background(ChirpTheme.roomVerificationSurface, in: .rect(cornerRadius: ChirpTheme.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: ChirpTheme.Radius.control)
                .strokeBorder(ChirpTheme.roomVerificationInk.opacity(0.35), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-verification-banner")
    }

    private var stackedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            if !targets.isEmpty {
                action.padding(.leading, typeSize.isAccessibilitySize ? 0 : 48)
            }
        }
    }

    private var detail: LocalizedMessage {
        let count = targets.count
        switch count {
        case 0: return "你已核验房间内的设备。正在等待其他成员完成互认或同步结果。"
        case 1: return "完成设备互认后，可恢复语音、聊天和附件发送。"
        default: return "还有 \(count) 台设备需要你核验。房间完成互认后即可继续。"
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(ChirpTheme.roomVerificationInk)
                .frame(width: 36, height: 36)
                .background(ChirpTheme.danger.opacity(0.13), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                MessageText("语音和聊天已暂停")
                    .font(.headline).foregroundStyle(ChirpTheme.roomVerificationInk)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("room-verification-title")
                MessageText(detail)
                    .font(.callout).foregroundStyle(ChirpTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("room-verification-detail")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var action: some View {
        if targets.count == 1, let target = targets.first {
            Button { verify(target.id) } label: {
                actionLabel("核验「\(target.displayName)」的设备")
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(ChirpTheme.roomVerificationInk)
            .accessibilityIdentifier("room-verify-single-device")
        } else if targets.count > 1 {
            Menu {
                ForEach(targets) { target in
                    Button { verify(target.id) } label: { Text(verbatim: target.displayName) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.2").accessibilityHidden(true)
                    MessageText("选择待核验设备")
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Rectangle().fill(ChirpTheme.roomVerificationInk.opacity(0.25))
                        .frame(width: 1, height: 14).accessibilityHidden(true)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold)).accessibilityHidden(true)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ChirpTheme.roomVerificationInk)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(ChirpTheme.surface.opacity(0.65), in: .rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(ChirpTheme.roomVerificationInk.opacity(0.24))
                }
                .roomActionTarget().contentShape(.rect)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .messageAccessibilityLabel("选择待核验设备")
            .accessibilityIdentifier("room-verify-device-menu")
        }
    }

    private func actionLabel(_ title: LocalizedMessage) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield").accessibilityHidden(true)
            MessageText(title).lineLimit(1)
        }
        .font(.callout.weight(.semibold))
        .roomActionTarget()
    }
}

struct RoomIdentityStatusCard: View {
    let trust: RoomIdentity.VoiceTrust

    private var needsAttention: Bool { trust == .pending || trust == .stopped }
    private var tint: Color { needsAttention ? ChirpTheme.danger : ChirpTheme.accent }
    private var title: LocalizedMessage {
        switch trust {
        case .solo: "等朋友加入"
        case .pending: "语音和聊天已暂停"
        case .rebuilding: "正在更新安全连接"
        case .trusted: "可信加密语音"
        case .stopped: "语音已停止"
        }
    }
    private var symbol: String {
        switch trust {
        case .solo: "person.wave.2"
        case .pending: "exclamationmark.shield"
        case .rebuilding: "arrow.triangle.2.circlepath"
        case .trusted: "checkmark.shield"
        case .stopped: "mic.slash"
        }
    }
    private var detail: LocalizedMessage {
        switch trust {
        case .solo: "这里暂时只有你，朋友加入后就能开聊。"
        case .pending: "完成设备互认后，可恢复语音、聊天和附件发送。"
        case .rebuilding: "全员核验完成，正在建立新的加密密钥，保持静音。"
        case .trusted: "当前所有参与设备已互认，可信加密语音已就绪。"
        case .stopped: "语音已停止，请检查授权状态或重新核验。"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.medium)).foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.10), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    MessageText(title).font(.subheadline.weight(.semibold))
                        .foregroundStyle(ChirpTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                MessageText(detail).font(.caption).foregroundStyle(ChirpTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(ChirpTheme.surface, in: .rect(cornerRadius: ChirpTheme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: ChirpTheme.Radius.card)
                .strokeBorder(needsAttention ? tint.opacity(0.4) : ChirpTheme.border.opacity(0.8), lineWidth: 0.75)
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier("room-identity-state")
    }
}
