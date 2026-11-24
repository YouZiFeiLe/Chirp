import SwiftUI

/// The account overview is shared; each platform owns its native navigation.
struct ClientSettingsView: View {
    @Environment(ApplicationSession.self) private var application
    @ObservedObject var call: CallController
    let memberID: String
    let memberName: String
    let logout: () -> Void
    let showProfileSettings: () -> Void
    let showCacheSettings: () -> Void
    let showLogSettings: () -> Void
    let showIdentitySettings: ((IdentitySettingsPage) -> Void)?
    let showAudioSettings: () -> Void
    @ScaledMetric(relativeTo: .body) private var avatarSize = 60

    var body: some View {
        Form {
            Section {
                Button(action: showProfileSettings) {
                    HStack(spacing: 18) {
                        IdentityAvatar(name: memberName, identity: memberID, size: min(avatarSize, 84))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: memberName).font(.system(.title2, design: .rounded, weight: .semibold))
                                .foregroundStyle(ChirpTheme.ink)
                            MessageText("让朋友更容易认出你")
                                .font(.callout).foregroundStyle(ChirpTheme.secondary)
                            MessageLabel("编辑个人资料", systemImage: "pencil")
                                .font(.caption.weight(.medium)).foregroundStyle(ChirpTheme.accent)
                                .padding(.top, 2)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .messageAccessibilityLabel("编辑个人资料")
                .accessibilityValue(Text(verbatim: memberName))
                .accessibilityIdentifier("profile-settings")
            }
            .listRowBackground(ChirpTheme.surface)

            Section {
                action("声音设置", subtitle: "麦克风、扬声器与音频处理", icon: "slider.horizontal.3", action: showAudioSettings)
                    .accessibilityIdentifier("settings-audio-preset")
                action("存储与缓存", subtitle: "管理附件与本机存储空间", icon: "externaldrive", action: showCacheSettings)
                    .accessibilityIdentifier("attachment-cache-settings")
                action("日志管理", subtitle: "记录、导出或清除本机日志", icon: "doc.text", action: showLogSettings)
                    .accessibilityIdentifier("log-settings")
                LanguagePicker(title: "界面语言", settingsRow: true)
            } header: { MessageText("使用偏好") }
            .listRowBackground(ChirpTheme.surface)

            if let showIdentitySettings {
                Section {
                    if application.networkClock.status != .ready { NetworkClockNotice(clock: application.networkClock) }
                    action("个人设备", subtitle: "查看、重命名与管理已授权设备", icon: "laptopcomputer.and.iphone") { showIdentitySettings(.devices) }
                        .accessibilityIdentifier("identity-settings-action")
                    action("黑名单", subtitle: "查看被拉黑的用户与设备指纹", icon: "hand.raised") { showIdentitySettings(.blacklist) }
                        .accessibilityIdentifier("blacklist-settings-action")
                    action("授权新设备", subtitle: "扫描或导入新设备的二维码", icon: "qrcode.viewfinder") {
                        if application.networkClock.isReadyNow() { showIdentitySettings(.authorizeDevice) }
                    }
                    .disabled(application.networkClock.status != .ready)
                    .accessibilityIdentifier("authorize-device-settings-action")
                    action("本机身份与数据", subtitle: "查看账号指纹或清空本地数据", icon: "key.horizontal") { showIdentitySettings(.local) }
                        .accessibilityIdentifier("local-identity-settings-action")
                } header: { MessageText("设备与安全") }
                .listRowBackground(ChirpTheme.surface)
            }

            Section {
                LabeledContent {
                    Text(verbatim: call.clientSession?.connection.apiURL.host ?? "—")
                        .foregroundStyle(ChirpTheme.secondary).textSelection(.enabled)
                } label: { MessageText("服务器") }
                LabeledContent {
                    Text(verbatim: appVersion).monospacedDigit().foregroundStyle(ChirpTheme.secondary)
                } label: { MessageText("版本") }
            } header: { MessageText("关于 Chirp") }
            .listRowBackground(ChirpTheme.surface)

            Section {
                Button(role: .destructive, action: logout) {
                    MessageLabel("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.body.weight(.medium)).foregroundStyle(ChirpTheme.danger)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center).contentShape(.rect)
                }
                .buttonStyle(.plain).accessibilityIdentifier("logout")
            }
            .listRowBackground(ChirpTheme.surface)

            Section {
                MessageText("Chirp守护您的每一次通话")
                    .font(.caption).foregroundStyle(ChirpTheme.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        .formStyle(.grouped).chirpForm()
        #if os(iOS)
        .messageNavigationTitle("我的")
        .listSectionSpacing(24).navigationBarTitleDisplayMode(.large)
        #else
        .messageNavigationTitle("设置")
        #endif
    }

    private func action(_ title: LocalizedMessage, subtitle: LocalizedMessage, icon: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) { SettingsRow(title: title, subtitle: subtitle, systemImage: icon) }
            .buttonStyle(.plain)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}

#if os(macOS)
struct MacSettingsView: View {
    @Environment(ApplicationSession.self) private var application
    @Environment(LoginSession.self) private var login
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeSheet: Detail?
    #if DEBUG
    @Environment(\.chirpDesignPreview) private var isPreview
    @State private var previewProfile = ProfileEditorSample()
    #endif
    private enum Detail: String, Identifiable {
        case profile, audio, cache, logs
        var id: String { rawValue }
    }

    var body: some View {
        TabView {
            overview.tabItem { MessageLabel("通用", systemImage: "gearshape") }
            IdentitySettingsContent(page: .devices).tabItem { MessageLabel("个人设备", systemImage: "laptopcomputer.and.iphone") }
            IdentitySettingsContent(page: .blacklist).tabItem { MessageLabel("黑名单", systemImage: "hand.raised") }
            if login.session != nil || previewMemberName != nil || !application.identity.savedScopes.isEmpty {
                IdentitySettingsContent(page: .authorizeDevice).tabItem { MessageLabel("授权新设备", systemImage: "qrcode.viewfinder") }
            }
            IdentitySettingsContent(page: .local).tabItem { MessageLabel("本机身份与数据", systemImage: "key.horizontal") }
        }
        .logScreen("settings")
        .task(id: scenePhase) {
            // Settings can be the only open macOS window.
            if scenePhase == .active { await application.networkClock.monitor() }
        }
        .frame(width: 660, height: 720)
        .tint(ChirpTheme.accent)
        .sheet(item: $activeSheet) { detail in
            switch detail {
            case .profile:
                if login.session != nil { ProfileEditView() }
                #if DEBUG
                if login.session == nil && isPreview { ProfileEditor(sample: $previewProfile) }
                #endif
            case .audio: AudioPresetSettingsView(call: application.call)
            case .cache: AttachmentCacheSettingsView()
            case .logs: LogManagementView()
            }
        }
        .onChange(of: login.session?.credential) { if activeSheet != .logs { activeSheet = nil } }
    }

    private var previewMemberName: String? {
        #if DEBUG
        isPreview ? previewProfile.name : nil
        #else
        nil
        #endif
    }

    private func accountOverview(memberID: String, name: String) -> some View {
        ClientSettingsView(call: application.call, memberID: memberID, memberName: name,
            logout: {
                application.call.leave()
                Task { [login] in await login.logout() }
                dismissWindow()
            },
            showProfileSettings: { activeSheet = .profile }, showCacheSettings: { activeSheet = .cache },
            showLogSettings: { activeSheet = .logs }, showIdentitySettings: nil, showAudioSettings: { activeSheet = .audio })
    }

    @ViewBuilder private var overview: some View {
        if let member = login.session?.member {
            accountOverview(memberID: member.id, name: login.profiles.displayName(for: member.id, fallback: member.displayName))
        } else if let previewMemberName {
            accountOverview(memberID: "design", name: previewMemberName)
        } else {
            Form {
                Section {
                    LanguagePicker(title: "界面语言")
                    Button { activeSheet = .logs } label: { MessageLabel("日志管理", systemImage: "doc.text") }
                        .accessibilityIdentifier("log-settings")
                }
                Section { MessageText("登录后可管理账号、设备与使用偏好。") }
            }.formStyle(.grouped).chirpForm()
        }
    }
}
#endif
