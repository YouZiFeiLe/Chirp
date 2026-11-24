import SwiftUI

struct IdentityDeviceCard: View {
    let device: RegisteredIdentityDevice
    let isCurrent: Bool
    let canRevoke: Bool
    let rename: () -> Void
    let revoke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                SettingsIcon(systemImage: platformIcon)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: device.name).font(.headline).foregroundStyle(ChirpTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: platformName).font(.caption).foregroundStyle(ChirpTheme.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button(action: rename) { MessageLabel("重命名设备", systemImage: "pencil") }
                    if !isCurrent && !device.revoked {
                        Button(role: .destructive, action: revoke) { MessageLabel("撤销此设备", systemImage: "minus.circle") }
                            .disabled(!canRevoke)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44).contentShape(.rect)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .messageAccessibilityLabel("设备操作").accessibilityValue(Text(verbatim: device.name))
                .accessibilityIdentifier("device-actions-\(device.id)")
            }
            if device.revoked {
                SettingsStatus(title: "已永久撤销", systemImage: "xmark.shield", color: ChirpTheme.danger)
            } else if isCurrent {
                SettingsStatus(title: "当前设备", systemImage: "checkmark.circle")
            } else {
                SettingsStatus(title: "已授权", systemImage: "checkmark.shield")
            }
            IdentityFingerprint(key: device.deviceKey)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 32) { timestamps }
                VStack(alignment: .leading, spacing: 12) { timestamps }
            }
            if isCurrent {
                MessageText("当前设备，不能自助撤销").font(.caption).foregroundStyle(ChirpTheme.secondary)
            } else if !device.revoked && !canRevoke {
                MessageText("至少需要保留一台有效设备。").font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
        }
        .chirpSurface(padding: 20)
        .accessibilityIdentifier("identity-device-\(device.id)")
    }

    private var timestamps: some View {
        Group {
            timestamp("最后上线时间", value: device.lastLoginAt)
            timestamp("首次注册时间", value: device.createdAt)
        }
    }

    private func timestamp(_ title: LocalizedMessage, value: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            MessageText(title).foregroundStyle(ChirpTheme.secondary)
            if let value, value > 0 {
                Text(Date(timeIntervalSince1970: TimeInterval(value)), format: .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
                    .foregroundStyle(ChirpTheme.ink)
            } else { MessageText("暂无记录").foregroundStyle(ChirpTheme.secondary) }
        }
        .font(.caption).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var platformIcon: String {
        switch device.platform.lowercased() {
        case "macos", "mac": "laptopcomputer"
        case "ios", "iphone": "iphone"
        case "ipados": "ipad"
        case "windows", "linux": "desktopcomputer"
        case "android": "smartphone"
        default: "desktopcomputer"
        }
    }

    private var platformName: String {
        switch device.platform.lowercased() {
        case "macos", "mac": "macOS"
        case "ios", "iphone": "iOS"
        case "ipados": "iPadOS"
        case "windows": "Windows"
        case "android": "Android"
        case "linux": "Linux"
        default: device.platform
        }
    }
}

struct BlacklistUserCard: View {
    let user: BlacklistedIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                IdentityAvatar(name: user.name, identity: user.accountID, size: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: user.name).font(.headline).foregroundStyle(ChirpTheme.ink)
                    Text(verbatim: user.accountID).font(.caption).foregroundStyle(ChirpTheme.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsStatus(title: user.accountBlocked ? "账号已被拉黑" : "设备已被拉黑", systemImage: "hand.raised", color: ChirpTheme.danger)
            ForEach(user.devices, id: \.sequence) { record in
                VStack(alignment: .leading, spacing: 8) {
                    IdentityFingerprint(key: record.subject)
                    Text(Date(timeIntervalSince1970: TimeInterval(record.createdAt)), format: .dateTime.year().month().day().hour().minute())
                        .font(.caption).foregroundStyle(ChirpTheme.secondary)
                }
            }
            if user.devices.isEmpty {
                MessageText("暂无设备指纹记录").font(.callout).foregroundStyle(ChirpTheme.secondary)
                IdentityFingerprint(key: user.accountKey, title: "账号指纹")
            }
            if user.accountBlocked {
                MessageText("该账号的所有设备均已被拉黑。").font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
        }
        .chirpSurface(padding: 20)
        .accessibilityIdentifier("blacklist-user-\(user.id)")
    }
}
