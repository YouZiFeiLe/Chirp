#if DEBUG
import ChirpMLS
import SwiftUI

/// Display-only data, with no credentials, signing material, or network session.
enum SettingsDesignSamples {
    static func key(_ byte: UInt8) -> String { Data(repeating: byte, count: 32).base64EncodedString() }
    static let devices: [RegisteredIdentityDevice] = [
        device(1, name: "我的 MacBook Pro", platform: "macos"),
        device(2, name: "随身的 iPhone", platform: "ios"),
        device(3, name: "旧电脑", platform: "macos", revoked: true),
    ]
    static var friends: [IdentityFriend] { emptyState ? [] : sampleFriends }
    static var blacklist: [BlacklistRecord] { emptyState ? [] : sampleBlacklist }
    private static var emptyState: Bool { ProcessInfo.processInfo.arguments.contains("--empty-social-preview") }
    private static let sampleFriends = [
        IdentityFriend(accountID: "member_lin", accountKey: key(4), name: "小林", trustedDevices: [key(5), key(6)]),
        IdentityFriend(accountID: "member_alex", accountKey: key(7), name: "Alex", trustedDevices: [key(8)]),
        IdentityFriend(accountID: "member_yuan", accountKey: key(9), name: "阿远"),
    ]
    private static let sampleBlacklist = [
        BlacklistRecord(sequence: 1, kind: "account", subject: "member_old", accountID: "member_old", accountKey: key(10), username: "Former account", createdAt: 1794816000),
        BlacklistRecord(sequence: 2, kind: "device", subject: key(11), accountID: "member_old", accountKey: key(10), username: "Former account", createdAt: 1794816000),
        BlacklistRecord(sequence: 3, kind: "device", subject: key(12), accountID: "member_other", accountKey: key(13), username: "Retired device", createdAt: 1794902400),
    ]

    private static func device(_ byte: UInt8, name: String, platform: String, revoked: Bool = false) -> RegisteredIdentityDevice {
        RegisteredIdentityDevice(deviceKey: key(byte), accountID: "member_design", accountKey: key(0),
            device: V5Device(accountKey: key(0), certificates: []), name: name, platform: platform,
            createdAt: 1792224000, lastLoginAt: byte == 3 ? nil : 1794902400, revoked: revoked)
    }
}

#Preview("个人设备 · 浅色") {
    let application = ApplicationSession()
    IdentitySettingsContent(page: .devices).environment(application).environment(application.login)
        .environment(\.chirpDesignPreview, true).preferredColorScheme(.light)
}
#Preview("黑名单 · 深色") {
    let application = ApplicationSession()
    IdentitySettingsContent(page: .blacklist).environment(application).environment(application.login)
        .environment(\.chirpDesignPreview, true).preferredColorScheme(.dark)
}
#Preview("黑名单为空") {
    SettingsEmptyState(title: "黑名单为空", subtitle: "目前没有被拉黑的用户或设备。", systemImage: "checkmark.shield")
        .padding(24).background(ChirpTheme.canvas)
}
#Preview("好友") {
    let application = ApplicationSession()
    FriendsView().environment(application).environment(\.chirpDesignPreview, true)
}

/// Only advances display states; never starts SAS, signs events, or accesses a real account.
struct SASVerificationPreview: View {
    @State private var step: SASVerificationStep = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--verification-busy") { return .ended(.peerBusy) }
        return arguments.contains("--verification-comparison") ? .comparison : .preparation
    }()
    @State private var isFriend = false
    @State private var dark = ProcessInfo.processInfo.arguments.contains("--verification-dark")

    var body: some View {
        SASVerificationContent(name: "小林", identity: "member_lin.login_preview.entry_preview", device: nil,
            step: step, decimals: [4829, 7316, 2058], isFriend: isFriend, action: perform)
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .principal) {
                    MessageText("离线设计预览 · 示例数据").font(.caption).foregroundStyle(ChirpTheme.secondary)
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("准备核验") { step = .preparation }
                        Button("朋友邀请你核验设备") { step = .invitation }
                        Button("等待朋友接受邀请") { step = .waitingForPeer }
                        Button("比较安全码") { step = .comparison }
                        Button("你已确认，等待朋友") { step = .confirmation }
                        Button("设备互认完成") { step = .completed }
                        Button("设备信任尚未同步") { step = .syncPending }
                        Button("对方正忙") { step = .ended(.peerBusy) }
                        Button("核验等待超时") { step = .ended(.timedOut) }
                        Divider()
                        Toggle("深色", isOn: $dark)
                    } label: { MessageLabel("预览选项", systemImage: "paintpalette") }
                }
            }
            .preferredColorScheme(dark ? .dark : .light)
    }

    private func perform(_ action: SASVerificationAction) {
        switch action {
        case .start: step = step == .ended(.peerBusy) ? .waitingForPeer : .comparison
        case .accept: step = .comparison
        case .confirm: step = .confirmation
        case .mismatch: step = .ended(.mismatch)
        case .retry, .close: step = .preparation
        case .sync: step = .completed
        case .addFriend: isFriend = true
        }
    }
}

#Preview("设备互认") { SASVerificationPreview() }
#endif
