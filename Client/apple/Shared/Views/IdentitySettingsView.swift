import ChirpMLS
import SwiftUI

enum IdentitySettingsPage: String, Identifiable {
    case devices, blacklist, authorizeDevice, local
    var id: String { rawValue }
    var logScreen: StaticString {
        switch self {
        case .devices: "devices"
        case .blacklist: "blacklist"
        case .authorizeDevice: "authorizeDevice"
        case .local: "localIdentity"
        }
    }
    var title: LocalizedMessage {
        switch self {
        case .devices: "个人设备"
        case .blacklist: "黑名单"
        case .authorizeDevice: "授权新设备"
        case .local: "本机身份与数据"
        }
    }
}

struct IdentitySettingsView: View {
    var page: IdentitySettingsPage = .devices
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            IdentitySettingsContent(page: page, onReset: { dismiss() })
                .messageNavigationTitle(page.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: { MessageText("完成") }
                    }
                }
        }
        #if os(macOS)
        .frame(width: 660, height: 720)
        #endif
    }
}

struct IdentitySettingsContent: View {
    let page: IdentitySettingsPage
    var onReset: () -> Void = {}
    @Environment(ApplicationSession.self) private var application
    @Environment(LoginSession.self) private var login
    @State private var error: String?
    @State private var resetConfirmation = false
    @State private var renaming: RegisteredIdentityDevice?
    @State private var revoking: RegisteredIdentityDevice?
    @State private var isRevoking = false
    private var identity: DeviceIdentityStore { application.identity }
    private var social: SocialIdentity { application.social }

    private var devices: [RegisteredIdentityDevice] {
        #if DEBUG
        if isPreview { return SettingsDesignSamples.devices }
        #endif
        return social.devices.sorted { lhs, rhs in
            if (lhs.deviceKey == identity.device?.leafKey) != (rhs.deviceKey == identity.device?.leafKey) {
                return lhs.deviceKey == identity.device?.leafKey
            }
            if lhs.revoked != rhs.revoked { return !lhs.revoked }
            return lhs.createdAt > rhs.createdAt
        }
    }
    private var blockedUsers: [BlacklistedIdentity] {
        #if DEBUG
        if isPreview { return BlacklistedIdentity.grouped(SettingsDesignSamples.blacklist) }
        #endif
        return BlacklistedIdentity.grouped(social.blacklist)
    }
    #if DEBUG
    @Environment(\.chirpDesignPreview) private var isPreview
    #endif
    private var previewEnabled: Bool {
        #if DEBUG
        isPreview
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            switch page {
            case .devices, .blacklist:
                syncedSettings
            case .authorizeDevice:
                DeviceAuthorizationSettingsView()
            case .local:
                localSettings
                    .modifier(LocalDataResetConfirmation(isPresented: $resetConfirmation, onComplete: onReset))
            }
        }
        .tint(ChirpTheme.accent)
        .logScreen(page.logScreen)
        .task { if login.session != nil { await social.refresh() } }
    }

    private var syncedSettings: some View {
        Group {
            if login.session == nil && !previewEnabled {
                SettingsEmptyState(title: "登录后查看设备与黑名单", subtitle: "登录后可管理账号、设备与使用偏好。", systemImage: "person.crop.circle")
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(ChirpTheme.canvas)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if page == .devices { deviceList } else { blacklist }
                        if let error = error ?? (previewEnabled ? nil : social.failure) { SettingsFailure(message: error) }
                    }
                    .frame(maxWidth: 640).padding(24).frame(maxWidth: .infinity)
                }
                .background(ChirpTheme.canvas)
                .refreshable { await social.refresh() }
            }
        }
        .sheet(item: $renaming) { device in
            DeviceRenameView(device: device) { name in
                guard let session = login.session else { throw ClientFailure(.unauthorized) }
                let api = APIClient(baseURL: session.connection.apiURL, credential: session.credential)
                defer { api.close() }
                try await api.renameIdentityDevice(device.deviceKey, name: name)
                await social.refresh()
            }
        }
        .confirmationDialog("撤销此设备的服务端资格", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            if let device = revoking {
                Button(role: .destructive) { revoking = nil; Task { await revoke(device) } } label: { MessageText("撤销此设备") }
            }
        } message: {
            if let device = revoking {
                Text(verbatim: device.name)
                MessageText("此设备身份将进入永久黑名单，不能恢复。已登记的后代设备保持有效。")
            }
        }
    }

    private var deviceList: some View {
        Group {
            SettingsPageHeading(title: "你的设备，都在这里", subtitle: "管理已授权设备，守护你的账号身份。", systemImage: "laptopcomputer.and.iphone")
            syncStatus
            if isRevoking { ProgressView { MessageText("正在撤销设备…") }.frame(maxWidth: .infinity) }
            if devices.isEmpty {
                if social.isRefreshing {
                    ProgressView().frame(maxWidth: .infinity).padding(32)
                } else {
                    SettingsEmptyState(title: "暂无设备", subtitle: "已登记的个人设备将在这里显示。", systemImage: "laptopcomputer.and.iphone")
                }
            } else {
                ChirpSectionHeading(title: "个人设备", detail: "\(devices.count) 台设备")
                LazyVStack(spacing: 16) {
                    ForEach(devices) { device in
                        IdentityDeviceCard(device: device, isCurrent: currentDeviceKey == device.deviceKey,
                            canRevoke: canRevoke(device), rename: { renaming = device }, revoke: { revoking = device })
                            .disabled(isRevoking)
                    }
                }
                MessageText("最后上线时间为此设备最近一次成功登录的时间。")
                    .font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
        }
    }

    private var blacklist: some View {
        Group {
            SettingsPageHeading(title: "黑名单", subtitle: "被永久撤销的用户与设备，集中在这里核对。", systemImage: "hand.raised")
            syncStatus
            if blockedUsers.isEmpty {
                if social.isRefreshing {
                    ProgressView().frame(maxWidth: .infinity).padding(32)
                } else if previewEnabled || social.failure == nil {
                    SettingsEmptyState(title: "黑名单为空", subtitle: "目前没有被拉黑的用户或设备。", systemImage: "checkmark.shield")
                        .accessibilityIdentifier("blacklist-empty")
                }
            } else {
                ChirpSectionHeading(title: "被拉黑的用户", detail: "\(blockedUsers.count) 位用户")
                LazyVStack(spacing: 16) {
                    ForEach(blockedUsers) { user in BlacklistUserCard(user: user) }
                }
                MessageText("黑名单由服务器同步，永久撤销的身份无法恢复。")
                    .font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
        }
    }

    private var syncStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if previewEnabled {
                    MessageLabel("离线设计预览 · 示例数据", systemImage: "paintpalette")
                        .font(.caption).foregroundStyle(ChirpTheme.secondary)
                } else if social.isRefreshing {
                    ProgressView().controlSize(.small)
                    MessageText("正在同步…").font(.caption).foregroundStyle(ChirpTheme.secondary)
                } else {
                    MessageLabel(social.voiceAllowed ? "黑名单已同步" : "等待同步", systemImage: social.voiceAllowed ? "checkmark.shield" : "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.medium)).foregroundStyle(ChirpTheme.secondary)
                }
                Spacer(minLength: 0)
                Button { Task { await social.refresh() } } label: { MessageLabel("刷新", systemImage: "arrow.clockwise").frame(minHeight: 32) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(social.isRefreshing || login.session == nil)
                    .accessibilityIdentifier("refresh-identity-settings")
            }
            if !social.voiceAllowed, login.session != nil {
                MessageText("授权状态缺失或已过期，聊天已暂停")
                    .font(.caption).foregroundStyle(ChirpTheme.warning)
            }
        }
    }

    private var localSettings: some View {
        Form {
            Section {
                SettingsPageHeading(title: "本机身份与数据", subtitle: "查看账号指纹或清空本地数据", systemImage: "key.horizontal")
            }.listRowBackground(Color.clear)
            SavedAccountIdentitySection(identity: identity, showsPicker: login.session == nil)
            Section {
                Button(role: .destructive) { resetConfirmation = true } label: {
                    SettingsRow(title: "清空全部本地数据", subtitle: "移除此客户端保存的身份、偏好与缓存", systemImage: "trash", color: ChirpTheme.danger)
                }
                .buttonStyle(.plain).accessibilityIdentifier("reset-local-identity")
            } header: { MessageText("本机身份重置") } footer: { MessageText(LocalDataResetConfirmation.warning) }
        }
        .formStyle(.grouped).chirpForm()
    }

    private var currentDeviceKey: String? {
        #if DEBUG
        if isPreview { return SettingsDesignSamples.devices.first?.deviceKey }
        #endif
        return identity.device?.leafKey
    }
    private func canRevoke(_ device: RegisteredIdentityDevice) -> Bool {
        if previewEnabled { return !device.revoked && device.deviceKey != currentDeviceKey }
        guard !device.revoked, device.deviceKey != identity.device?.leafKey else { return false }
        return social.devices.contains { other in
            other.deviceKey != device.deviceKey && !other.revoked && (try? other.device.validate()) != nil
        }
    }
    private func revoke(_ device: RegisteredIdentityDevice) async {
        guard canRevoke(device), let session = login.session, !isRevoking else { return }
        isRevoking = true; error = nil; defer { isRevoking = false }
        let api = APIClient(baseURL: session.connection.apiURL, credential: session.credential); defer { api.close() }
        do { try await social.revokeDevice(device.deviceKey) }
        catch { self.error = error.localizedDescription }
    }
}

struct SavedAccountIdentitySection: View {
    let identity: DeviceIdentityStore
    let showsPicker: Bool
    @State private var failure: String?

    var body: some View {
        if !identity.savedScopes.isEmpty {
            Section {
                if showsPicker {
                    Picker("已保存的账号身份", selection: Binding(get: { identity.currentScope }, set: { scope in
                        do {
                            try identity.selectSavedScope(scope)
                            failure = nil
                        } catch {
                            failure = error.localizedDescription
                        }
                    })) {
                        ForEach(identity.savedScopes, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    MessageText("账号指纹").font(.caption).foregroundStyle(ChirpTheme.secondary)
                    Text(verbatim: identity.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                }.padding(.vertical, 8)
                if let failure { SettingsFailure(message: failure) }
            } header: { MessageText("已保存的账号身份") }
        }
    }
}

private struct DeviceRenameView: View {
    let device: RegisteredIdentityDevice
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSaving = false
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    init(device: RegisteredIdentityDevice, save: @escaping (String) async throws -> Void) {
        self.device = device; self.save = save
        _name = State(initialValue: device.name)
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !isSaving && !trimmedName.isEmpty && trimmedName != device.name && trimmedName.count <= 80 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("设备名称", text: $name).focused($nameFocused)
                        .onSubmit { submit() }.accessibilityIdentifier("rename-device-name")
                } header: { MessageText("设备名称") } footer: { MessageText("取一个容易辨认的名称，例如「家里的 Mac」。") }
                if let failure { Section { SettingsFailure(message: failure) } }
            }
            .formStyle(.grouped).chirpForm().messageNavigationTitle("重命名设备")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { MessageText("取消") }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { submit() } label: {
                        if isSaving { ProgressView().controlSize(.small) } else { MessageText("保存名称") }
                    }.disabled(!canSave).accessibilityIdentifier("save-device-name")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear { nameFocused = true }
        #if os(macOS)
        .frame(width: 420, height: 260)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
    private func submit() {
        guard canSave else { return }
        isSaving = true; failure = nil
        Task {
            defer { isSaving = false }
            do { try await save(trimmedName); dismiss() } catch { failure = error.localizedDescription }
        }
    }
}

struct LocalDataResetConfirmation: ViewModifier {
    @Environment(ApplicationSession.self) private var application
    @Binding var isPresented: Bool
    var onComplete: () -> Void = {}
    @State private var isResetting = false
    @State private var failure: String?

    static let warning: LocalizedMessage = "清空本客户端管理的设备密钥、证书、账号绑定、登录会话、好友与核验、个人信任、黑名单缓存、配置、缓存、本地内容和未完成设置。系统权限、密码管理器和另行导出的文件不受影响。不会撤销服务端账号、设备或其他设备的数据。"

    func body(content: Content) -> some View {
        content
            .disabled(isResetting)
            .interactiveDismissDisabled(isResetting)
            .overlay {
                if isResetting {
                    VStack(spacing: 12) {
                        ProgressView()
                        MessageText("正在清空本地数据…")
                    }
                    .padding(24)
                    .background(.regularMaterial, in: .rect(cornerRadius: ChirpTheme.Radius.control))
                }
            }
            .alert("清空本地数据", isPresented: $isPresented) {
                Button(role: .destructive) { reset() } label: { MessageText("确认清空全部本地数据") }
                    .accessibilityIdentifier("confirm-clear-local-data")
                Button(role: .cancel) {} label: { MessageText("取消") }
            } message: { MessageText(Self.warning) }
            .alert("清空本地数据失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button { failure = nil } label: { MessageText("完成") }
            } message: { Text(verbatim: failure ?? "") }
    }

    private func reset() {
        guard !isResetting else { return }
        isResetting = true
        Task { @MainActor in
            defer { isResetting = false }
            do {
                try await application.resetAllLocalData()
                onComplete()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
