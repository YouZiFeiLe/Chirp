import ChirpMLS
import SwiftUI

enum SASVerificationStep: Equatable {
    case preparation, invitation, waitingForPeer, exchanging, comparison, confirmation
    case saving, syncPending, completed, ended(SASVerificationPresentation.EndReason)

    var progress: Int {
        switch self {
        case .preparation, .invitation, .waitingForPeer, .exchanging, .ended: 1
        case .comparison: 2
        case .confirmation, .saving, .syncPending, .completed: 3
        }
    }
    var title: LocalizedMessage {
        switch self {
        case .preparation: "确认朋友，也确认设备"
        case .invitation: "朋友邀请你核验设备"
        case .waitingForPeer: "等待朋友接受邀请"
        case .exchanging: "正在生成安全码"
        case .comparison: "一起核对这三组数字"
        case .confirmation: "你已确认，等待朋友"
        case .saving: "正在保存设备信任"
        case .syncPending: "设备信任尚未同步"
        case .completed: "设备互认完成"
        case .ended(let reason):
            switch reason {
            case .mismatch: "安全码不一致，已停止核验"
            case .timedOut: "核验等待超时"
            case .peerBusy: "对方正忙"
            case .peerCancelled: "朋友已取消这次核验"
            case .roomChanged: "房间成员已变化"
            case .cancelled, .failed: "这次核验未完成"
            }
        }
    }
    var detail: LocalizedMessage {
        switch self {
        case .preparation: "用一次简短的安全码核对，确认正在与你相聚的是朋友的这台设备。"
        case .invitation: "先确认你正在与本人联系，再接受邀请。接受邀请不会立即建立信任。"
        case .waitingForPeer: "邀请已准备好。请提醒对方打开 Chirp，接受设备互认邀请；安全码会自动出现。"
        case .exchanging: "双方正在交换核验信息，请保持 Chirp 打开，稍候片刻。"
        case .comparison: "请按顺序比较你和朋友屏幕上的全部数字，三组都一致后再确认。"
        case .confirmation: "请让朋友也点击「三组数字全部一致」。双方都确认后，才会保存设备信任。"
        case .saving: "安全码已由双方确认，正在同步这台设备的信任记录。"
        case .syncPending: "安全码已由双方确认，但信任记录尚未同步。请保持联网后重试同步，无需再次比较数字。"
        case .completed: "你已信任朋友的当前设备。以后使用同一台设备相聚时，可复用这份信任。"
        case .ended(let reason):
            switch reason {
            case .mismatch: "这次核验没有建立新的设备信任。请先通过可信渠道确认联系的是本人，再重新核验。"
            case .timedOut: "对方可能暂时离开或网络不稳定。这次核验已结束，联系上对方后可以重新开始。"
            case .peerBusy: "对方正在进行设备核验。你可以稍后重新邀请，或返回房间选择其他成员。"
            case .peerCancelled: "这次核验没有建立新的设备信任。可以先联系对方，准备好后再试一次。"
            case .roomChanged: "为确保核验的是当前参与的设备，这次核验已结束。请确认对方仍在房间后重新开始。"
            case .cancelled: "这次核验已取消，没有建立新的设备信任。准备好后可以重新开始。"
            case .failed: "核验遇到了问题，没有建立新的设备信任。请检查网络与对方的在线状态后重试。"
            }
        }
    }
}

enum SASVerificationAction { case start, accept, confirm, mismatch, retry, sync, close, addFriend }

struct SASVerificationView: View {
    let room: RoomIdentity
    let peer: MLSPeer
    @Environment(\.dismiss) private var dismiss
    @State private var isAddingFriend = false
    @State private var friendFailure: String?

    private var step: SASVerificationStep {
        switch room.verificationPresentation?.phase {
        case .preparation: return .preparation
        case .savingTrust: return .saving
        case .trustPending: return .syncPending
        case .completed: return .completed
        case .ended(let reason): return .ended(reason)
        case .active:
            guard let v = room.verification else { return .exchanging }
            if !v.accepted { return .invitation }
            if v.awaitingPeerAcceptance { return .waitingForPeer }
            if v.decimals.count != 3 { return .exchanging }
            return v.confirmed ? .confirmation : .comparison
        case nil: return .ended(.cancelled)
        }
    }
    private var isFriend: Bool {
        room.social.friends.contains { $0.accountID == MemberProfile.memberID(for: peer.identity) && $0.accountKey == peer.binding?.device.accountKey }
    }
    private var trustsDevice: Bool {
        peer.binding.map { room.social.trusts(accountID: MemberProfile.memberID(for: peer.identity), device: $0.device) } ?? false
    }
    private var error: String? {
        if case .ended(.failed(let message)) = step { return message }
        return step == .syncPending ? room.social.failure : friendFailure
    }

    var body: some View {
        SASVerificationContent(name: peer.name, identity: peer.identity, device: peer.binding?.device,
            step: step, decimals: room.verification?.decimals ?? [], trustsDevice: trustsDevice,
            isFriend: isFriend, isAddingFriend: isAddingFriend, canRetry: room.canVerify(peer),
            hasPendingTrustWrite: room.social.hasPendingTrustWrite, roomTrust: room.trust, failure: error, action: perform)
    }

    private func perform(_ action: SASVerificationAction) {
        switch action {
        case .start: Task { await room.startVerification(peer) }
        case .accept: Task { await room.acceptVerification() }
        case .confirm: Task { await room.confirmVerification(matches: true) }
        case .mismatch: Task { await room.confirmVerification(matches: false) }
        case .retry: room.prepareVerificationAgain()
        case .sync: Task { await room.retryVerificationTrustSync() }
        case .close: room.dismissVerification(); dismiss()
        case .addFriend:
            guard !isAddingFriend else { return }
            isAddingFriend = true; friendFailure = nil
            Task {
                defer { isAddingFriend = false }
                await room.addFriend(peer)
                if !isFriend { friendFailure = room.social.failure }
            }
        }
    }
}

/// The same content is used by the live flow and offline design previews.
struct SASVerificationContent: View {
    let name: String
    let identity: String
    let device: V5Device?
    let step: SASVerificationStep
    var decimals: [Int] = []
    var trustsDevice = false
    var isFriend = false
    var isAddingFriend = false
    var canRetry = true
    var hasPendingTrustWrite = false
    var roomTrust: RoomIdentity.VoiceTrust = .pending
    var failure: String?
    let action: (SASVerificationAction) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var focusesHeading: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    peerHeader
                    if step != .ended(.peerBusy) { SASVerificationProgress(step: step) }
                    mainCard
                    if let failure { SettingsFailure(message: failure).accessibilityIdentifier("sas-failure") }
                    if step == .preparation { friendAction }
                    deviceDetails
                }
                .frame(maxWidth: 560).padding(24).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("sas-verification-scroll")
            .background(ChirpTheme.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
            .messageNavigationTitle("设备互认")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { action(.close) } label: { MessageText(closeTitle) }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("close-sas-verification")
                }
            }
            .onChange(of: step, initial: true) { focusesHeading = true }
        }
        .tint(ChirpTheme.accent)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 600, minHeight: 520, idealHeight: 760)
        #endif
        .accessibilityIdentifier("sas-verification-page")
    }

    private var closeTitle: LocalizedMessage {
        switch step {
        case .invitation, .waitingForPeer, .exchanging, .comparison, .confirmation: "取消核验"
        default: "关闭"
        }
    }

    private var peerHeader: some View {
        HStack(spacing: 16) {
            IdentityAvatar(name: name, identity: identity, size: 56)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: name).font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(ChirpTheme.ink).fixedSize(horizontal: false, vertical: true)
                MessageText("核验朋友的当前设备").font(.subheadline).foregroundStyle(ChirpTheme.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var mainCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            if step == .completed {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 36, weight: .medium))
                    .foregroundStyle(ChirpTheme.accent).accessibilityHidden(true)
            } else if case .ended = step {
                let busy = step == .ended(.peerBusy)
                Image(systemName: busy ? "clock" : "exclamationmark.shield").font(.system(size: 32, weight: .medium))
                    .foregroundStyle(busy ? ChirpTheme.secondary : ChirpTheme.danger).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 10) {
                MessageText(step.title).font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(ChirpTheme.ink).accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focusesHeading).accessibilityIdentifier("sas-step-title")
                MessageText(step.detail).font(.callout).foregroundStyle(ChirpTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            stageContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chirpSurface(padding: 24)
    }

    @ViewBuilder private var stageContent: some View {
        switch step {
        case .preparation, .invitation:
            SASVerificationGuidance()
        case .comparison, .confirmation:
            SASDecimalGroups(decimals: decimals)
            SASVerificationNotice(title: step == .confirmation ? "你已确认三组数字一致" : "请当面或通过另一条可信渠道核对",
                detail: step == .confirmation ? "正在等待对方确认及身份密钥验证。" : "不要通过本房间或未经核验的聊天核对安全码。",
                systemImage: step == .confirmation ? "checkmark.circle" : "person.wave.2")
        case .waitingForPeer, .exchanging, .saving:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                MessageText(step == .saving ? "正在同步，请稍候" : "保持此页面打开，准备好后会自动继续")
                    .font(.subheadline).foregroundStyle(ChirpTheme.secondary)
            }.padding(.vertical, 12).accessibilityElement(children: .combine)
        case .completed:
            SASVerificationNotice(title: "仅信任这台设备", detail: "朋友更换设备后，需要重新核验。你可以在好友页面管理这份信任。", systemImage: "laptopcomputer.and.iphone")
            MessageText(roomTrust == .pending ? "房间中还有设备等待互认，全部完成后才能恢复语音和聊天。" : "房间会在所有设备完成互认并建立安全连接后恢复语音和聊天。")
                .font(.callout).foregroundStyle(ChirpTheme.secondary)
        case .syncPending:
            SASVerificationNotice(title: "设备信任待同步", detail: "请重试同步以保存信任记录。同步成功前不会新增设备信任。", systemImage: "arrow.triangle.2.circlepath")
        case .ended:
            if !canRetry {
                MessageText("对方已离开或更换设备。请返回房间，点击对方当前的头像重新核验。")
                    .font(.callout).foregroundStyle(ChirpTheme.secondary)
            }
        }
    }

    private var friendAction: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    friendExplanation
                    addFriendButton
                }
            } else {
                HStack(spacing: 12) {
                    friendExplanation
                    Spacer(minLength: 0)
                    addFriendButton
                }
            }
        }
    }

    private var friendExplanation: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemImage: isFriend ? "person.crop.circle.badge.checkmark" : "person.badge.plus")
            VStack(alignment: .leading, spacing: 4) {
                MessageText(isFriend ? "已在你的好友中" : "也可以先添加好友").font(.subheadline.weight(.medium)).foregroundStyle(ChirpTheme.ink)
                MessageText("添加好友是单向操作，不代表已核验设备。")
                    .font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var addFriendButton: some View {
        if !isFriend {
            Button { action(.addFriend) } label: {
                if isAddingFriend { ProgressView().controlSize(.small).frame(minWidth: 44, minHeight: 44) }
                else { MessageText("添加好友").frame(minHeight: 44).fixedSize(horizontal: true, vertical: false) }
            }
            .buttonStyle(.borderless).disabled(isAddingFriend)
            .accessibilityIdentifier("sas-add-friend")
        }
    }

    private var deviceDetails: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: MemberProfile.memberID(for: identity)).font(.caption).foregroundStyle(ChirpTheme.secondary).textSelection(.enabled)
                if let device {
                    IdentityFingerprint(key: device.accountKey, title: "账号指纹")
                    IdentityFingerprint(key: device.leafKey, title: "当前设备指纹")
                }
            }.padding(.top, 12)
        } label: {
            MessageLabel("账号与设备详情", systemImage: "info.circle")
                .font(.subheadline).foregroundStyle(ChirpTheme.secondary).frame(minHeight: 44)
        }
        .accessibilityIdentifier("sas-device-details")
    }

    private var actionBar: some View {
        SASVerificationActionBar(step: step, trustsDevice: trustsDevice, isAddingFriend: isAddingFriend,
                                 canRetry: canRetry, hasPendingTrustWrite: hasPendingTrustWrite, action: action)
            .frame(maxWidth: 560).padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: .infinity).background(ChirpTheme.surface)
            .overlay(alignment: .top) { Divider().overlay(ChirpTheme.border) }
    }
}
