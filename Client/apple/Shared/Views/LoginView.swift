import AuthenticationServices
import SwiftUI

struct LoginView: View {
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LoginSession.self) private var login
    @Environment(ApplicationSession.self) private var application
    #if os(macOS)
    @State private var serverAddressFocused = false
    #else
    @FocusState private var serverAddressFocused: Bool
    #endif
    @State private var operation: Operation?
    @State private var notice: LocalizedMessage?
    let localActions: LoginDeviceActions
    private enum Operation: Hashable { case check, login, register, phone }
    private var isBusy: Bool { operation != nil || login.server.isChecking }
    private var isAuthenticating: Bool { operation == .login }
    #if os(macOS)
    @Environment(\.fontResolutionContext) private var fontResolutionContext
    @State private var phoneLogin: PhoneLogin?
    private struct PhoneLogin: Identifiable {
        let id = UUID()
        let connection: ServerConnection
    }
    #endif

    var body: some View {
        Group {
        #if os(macOS)
        desktopLayout
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ChirpWordmark()
                ChirpEyebrow(title: "只属于你们的林间密语").padding(.top, 12)
                welcomeTitle
                loginForm()
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24).padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(ChirpTheme.canvas)
        // The form avoids the keyboard while these buttons stay at the bottom.
        .safeAreaInset(edge: .bottom, spacing: 0) { phoneFooter.hidden() }
        .overlay {
            VStack {
                Spacer(minLength: 0)
                phoneFooter
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        #endif
        }
        .logScreen("login")
        .task(id: operation) {
            guard let current = operation else { return }
            login.message = nil; notice = nil
            switch current {
            case .check: await login.server.confirm()
            case .login: await authenticate()
            case .register: await register()
            case .phone:
                #if os(macOS)
                if application.networkClock.isReadyNow(), let connection = login.server.connection { phoneLogin = PhoneLogin(connection: connection) }
                #else
                break
                #endif
            }
            if !Task.isCancelled, operation == current { operation = nil }
        }
        .onChange(of: application.networkClock.status == .ready) {
            guard application.networkClock.status != .ready else { return }
            if operation == .login || operation == .phone { operation = nil }
            #if os(macOS)
            phoneLogin = nil
            #endif
        }
        .onChange(of: login.server.address) { login.message = nil; notice = nil }
        #if os(macOS)
        .sheet(item: $phoneLogin) { PhoneLoginView(connection: $0.connection, identity: application.identity) }
        #endif
    }

    #if os(iOS)
    private var phoneFooter: some View {
        localActions
            .frame(maxWidth: 440)
            .padding(.horizontal, ChirpTheme.Space.xl)
            .frame(maxWidth: .infinity)
            .background(ChirpTheme.canvas)
    }
    #endif

    private var welcomeTitle: some View {
        MessageText("只有彼此能懂，\n他耳皆为鸟鸣。")
            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            .tracking(-1.2)
            .lineSpacing(6)
            .foregroundStyle(ChirpTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    #if os(macOS)
    private var desktopLayout: some View {
        GeometryReader { geometry in
            let formWidth = max(440, geometry.size.width - 480)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 24) {
                    ChirpWordmark()
                    Spacer(minLength: 24)
                    ChirpEyebrow(title: "只属于你们的林间密语")
                    welcomeTitle
                    MessageText("像林间的一声啁啾，\n穿过风声，只落入懂它的耳朵。")
                        .font(.body).lineSpacing(6).foregroundStyle(ChirpTheme.secondary)
                    QuietWave(size: 208).frame(maxWidth: .infinity).padding(.vertical, 12)
                    Spacer(minLength: 24)
                    MessageLabel("端到端加密·唯有听筒两端知晓", systemImage: "waveform")
                        .font(.subheadline).foregroundStyle(ChirpTheme.secondary)
                }
                .padding(44)
                .frame(width: geometry.size.width - formWidth, height: geometry.size.height, alignment: .leading)
                .background(LinearGradient(colors: [ChirpTheme.hero, ChirpTheme.surfaceSubtle],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))

                desktopLoginForm(width: formWidth)
                    .frame(height: geometry.size.height)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(ChirpTheme.canvas)
    }

    private func desktopLoginForm(width: CGFloat) -> some View {
        let baseWidth: CGFloat = 400
        let margin = min(44, max(24, (width - baseWidth) / 2))
        let availableWidth = width - 2 * margin
        let scale = min(1.08, max(1, availableWidth / baseWidth))
        return ScrollView {
            loginForm(cardScale: scale)
                .frame(maxWidth: baseWidth * scale)
                .padding(.horizontal, margin)
                .padding(.vertical, 44)
                .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .frame(width: width)
    }
    #endif

    private func loginForm(cardScale: CGFloat = 1) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            loginCard(scale: cardScale)
                .chirpSurface(padding: 24 * cardScale, cornerRadius: ChirpTheme.Radius.card * cardScale)
            #if os(macOS)
            localActions
            #endif
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: login.server.connection != nil)
    }

    private func loginCard(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24 * scale) {
            VStack(alignment: .leading, spacing: 10 * scale) {
                #if os(macOS)
                MessageText("欢迎回来")
                    .font(cardFont(.title, scale: scale, weight: .semibold))
                    .foregroundStyle(ChirpTheme.ink)
                #endif
                MessageText("用通行密钥，和其他鸟儿相聚。")
                    .font(cardFont(.subheadline, scale: scale)).foregroundStyle(ChirpTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            loginProgress(scale: scale)
            NetworkClockNotice(clock: application.networkClock)
            serverField(scale: scale)
            if let connection = login.server.connection {
                authenticationActions(for: connection, scale: scale)
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 12 * scale)))
                    .allowsHitTesting(login.server.connection != nil)
                    .accessibilityHidden(login.server.connection == nil)
            }
            if isBusy && operation != .check { ProgressView().controlSize(.small) }
            if let notice {
                MessageText(notice).font(cardFont(.callout, scale: scale)).foregroundStyle(ChirpTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("registration-message")
            }
            if let message = login.message {
                Label { FailureText(message) } icon: { Image(systemName: "exclamationmark.circle") }
                    .font(cardFont(.callout, scale: scale)).foregroundStyle(ChirpTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("login-message")
            }
        }
    }

    private func loginProgress(scale: CGFloat) -> some View {
        HStack(spacing: 12 * scale) {
            loginStep("连接空间", number: "1", complete: login.server.connection != nil, active: true, scale: scale)
            Rectangle().fill(ChirpTheme.border).frame(maxWidth: 28 * scale, minHeight: 1, maxHeight: 1)
                .accessibilityHidden(true)
            loginStep("验证身份", number: "2", complete: false, active: login.server.connection != nil, scale: scale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loginStep(_ title: LocalizedMessage, number: String, complete: Bool, active: Bool, scale: CGFloat) -> some View {
        HStack(spacing: 7 * scale) {
            Group {
                if complete { Image(systemName: "checkmark") }
                else { Text(verbatim: number) }
            }
            .font(cardFont(.caption2, scale: scale, weight: .semibold))
            .frame(width: 24 * scale, height: 24 * scale)
            .foregroundStyle(active ? ChirpTheme.onAccent : ChirpTheme.secondary)
            .background(active ? ChirpTheme.accent : ChirpTheme.surfaceSubtle, in: .circle)
            .accessibilityHidden(true)
            MessageText(title).font(cardFont(.caption, scale: scale, weight: .medium))
                .foregroundStyle(active ? ChirpTheme.ink : ChirpTheme.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func authenticationActions(for connection: ServerConnection, scale: CGFloat) -> some View {
        VStack(spacing: 12 * scale) {
            Button {
                operation = .login
            } label: {
                MessageLabel(isAuthenticating ? "正在等待通行密钥…" : "使用 Passkey 登录", systemImage: "person.badge.key.fill")
                    .font(cardFont(.body, scale: scale, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 32 * scale)
                    .modifier(ChirpProminentLabelStyle())
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            .tint(ChirpTheme.accent)
            .disabled(isBusy || application.networkClock.status != .ready)
            .accessibilityIdentifier("passkey-login")

            #if os(macOS)
            if connection.capabilities.deviceLogin {
                Button {
                    operation = .phone
                } label: {
                    MessageLabel("手机扫码登录", systemImage: "qrcode.viewfinder")
                        .font(cardFont(.body, scale: scale, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 32 * scale)
                        .foregroundStyle(ChirpTheme.ink)
                }
                .buttonStyle(.glass).controlSize(.large)
                .tint(.clear)
                .disabled(isBusy || application.networkClock.status != .ready)
                .accessibilityIdentifier("phone-login")

            }
            #endif
            if connection.capabilities.registration {
                Divider().overlay(ChirpTheme.border).padding(.top, 8 * scale)
                Button {
                    operation = .register
                } label: {
                    MessageLabel(operation == .register ? "正在打开注册网页…" : "申请加入空间", systemImage: "arrow.up.right")
                        .font(cardFont(.subheadline, scale: scale, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 44 * scale)
                        .foregroundStyle(ChirpTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityIdentifier("passkey-register")
            }
        }
    }

    private func serverField(scale: CGFloat) -> some View {
        @Bindable var server = login.server
        let checking = operation == .check || server.isChecking
        let hasAddress = !server.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let border = server.failure != nil ? ChirpTheme.danger :
            (serverAddressFocused || server.connection != nil ? ChirpTheme.accent : ChirpTheme.border)
        let radius = ChirpTheme.Radius.control * scale
        return VStack(alignment: .leading, spacing: 10 * scale) {
            MessageText("服务器地址")
                .font(cardFont(.subheadline, scale: scale, weight: .medium)).foregroundStyle(ChirpTheme.ink)
            HStack(spacing: 12 * scale) {
                Image(systemName: server.connection != nil ? "checkmark.circle.fill" : "link")
                    .font(cardFont(.body, scale: scale, weight: .medium))
                    .foregroundStyle(server.connection != nil ? ChirpTheme.accent : ChirpTheme.secondary)
                    .frame(width: 20 * scale)
                    .accessibilityHidden(true)
                #if os(macOS)
                MacServerAddressField(address: $server.address, isEditing: $serverAddressFocused,
                                      pointSize: cardFont(.callout, scale: scale).resolve(in: fontResolutionContext).pointSize,
                                      submit: confirmServerAddress)
                    .disabled(isBusy)
                #else
                TextField("", text: $server.address,
                          prompt: Text(verbatim: "chirp.example.com").foregroundStyle(ChirpTheme.secondary))
                    .textFieldStyle(.plain)
                    .font(cardFont(.callout, scale: scale, design: .monospaced))
                    .foregroundStyle(ChirpTheme.ink)
                    .tint(ChirpTheme.accent)
                    .focused($serverAddressFocused)
                    .keyboardType(.asciiCapable).textContentType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go)
                    .disabled(isBusy)
                    .onSubmit { confirmServerAddress() }
                    .messageAccessibilityLabel("服务器地址")
                    .accessibilityIdentifier("server-address")
                #endif
                Button {
                    confirmServerAddress()
                } label: {
                    HStack(spacing: 6 * scale) {
                        if checking { ProgressView().controlSize(.small).tint(ChirpTheme.accent) }
                        MessageText(checking ? "检测中…" : "确认")
                            .font(cardFont(.callout, scale: scale, weight: .semibold))
                    }
                    .foregroundStyle(hasAddress && !isBusy ? ChirpTheme.onAccent : ChirpTheme.secondary)
                    .padding(.horizontal, 14 * scale)
                    .frame(minHeight: 44 * scale)
                    .background(hasAddress && !isBusy ? ChirpTheme.accent : ChirpTheme.surfaceSubtle,
                                in: .rect(cornerRadius: radius - 4 * scale))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(isBusy || !hasAddress)
                .accessibilityIdentifier("confirm-server-address")
            }
            .padding(.leading, 16 * scale).padding(.trailing, 6 * scale).padding(.vertical, 6 * scale)
            .frame(minHeight: 56 * scale)
            .background(ChirpTheme.surface, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(border.opacity(serverAddressFocused ? 0.85 : 0.65),
                                  lineWidth: serverAddressFocused ? 1.5 : 1)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: serverAddressFocused)
            if let failure = server.failure {
                FailureText(failure).font(cardFont(.caption, scale: scale)).foregroundStyle(ChirpTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("server-address-status")
            } else if let message = server.notice {
                MessageLabel(message, systemImage: "checkmark.circle")
                    .font(cardFont(.caption, scale: scale)).foregroundStyle(ChirpTheme.accent)
                    .accessibilityIdentifier("server-address-status")
            }
        }
    }

    private func cardFont(_ style: Font.TextStyle, scale: CGFloat,
                          weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        let font = Font.system(style, design: design, weight: weight)
        #if os(macOS)
        if scale > 1 {
            let pointSize = font.resolve(in: fontResolutionContext).pointSize
            return .system(size: pointSize * scale, weight: weight ?? .regular, design: design)
        }
        #endif
        return font
    }

    private func confirmServerAddress() {
        guard !isBusy, !login.server.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        serverAddressFocused = false
        operation = .check
    }

    private func authenticate() async {
        ClientLog.shared.record(.account, "browserLogin", outcome: .started)
        let span = ClientLog.shared.begin()
        do {
            try application.networkClock.requireReady()
            let connection = try await login.server.prepareConnection()
            try Task.checkCancellation()
            try application.networkClock.requireReady()
            let request = try ClientLoginRequest(connection: connection)
            let callback = try await webAuthenticationSession.authenticate(
                using: request.authorizationURL, callback: .customScheme(ClientLoginRequest.callbackScheme),
                preferredBrowserSession: .ephemeral, additionalHeaderFields: [:])
            try Task.checkCancellation()
            try application.networkClock.requireReady()
            let setup = try await ClientLoginAPI.authenticate(request, callback: callback)
            guard !Task.isCancelled, login.server.connection == connection, login.session == nil else { throw CancellationError() }
            try await application.identitySetup.begin(setup, connection: connection, verifier: request.verifier)
            ClientLog.shared.finish(span, .account, "browserLogin")
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            ClientLog.shared.finish(span, .account, "browserLogin", error: CancellationError())
            if !Task.isCancelled, application.networkClock.isReadyNow() { login.message = ClientFailure(.loginCancelled) }
        } catch is CancellationError {
            ClientLog.shared.finish(span, .account, "browserLogin", error: CancellationError())
            return
        } catch {
            ClientLog.shared.finish(span, .account, "browserLogin", error: error)
            let failure = ClientFailure.capture(error, fallback: .loginIncomplete)
            if !Task.isCancelled, failure != ClientFailure(.networkTimeRequired) {
                login.message = login.server.failure == failure ? nil : failure
            }
        }
    }

    private func register() async {
        ClientLog.shared.record(.account, "openRegistration", outcome: .started)
        let span = ClientLog.shared.begin()
        do {
            let connection = try await login.server.prepareConnection()
            guard connection.capabilities.registration else { throw ClientFailure(.invalidServerConfiguration) }
            let url = connection.registrationURL
            try Task.checkCancellation()
            guard login.server.connection == connection else { throw CancellationError() }
            let opened = await BrowserOpener.open(url) { target, completion in
                openURL(target, completion: completion)
            }
            try Task.checkCancellation()
            guard opened else { throw ClientFailure(.browserOpenFailed) }
            ClientLog.shared.finish(span, .account, "openRegistration")
            notice = "请在浏览器完成注册，管理员批准后返回登录。"
        } catch is CancellationError {
            ClientLog.shared.finish(span, .account, "openRegistration", error: CancellationError())
            return
        } catch {
            ClientLog.shared.finish(span, .account, "openRegistration", error: error)
            let failure = ClientFailure.capture(error)
            login.message = login.server.failure == failure ? nil : failure
        }
    }
}

#if os(macOS)
private struct MacServerAddressField: NSViewRepresentable {
    @Binding var address: String
    @Binding var isEditing: Bool
    let pointSize: CGFloat
    let submit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.isAutomaticTextCompletionEnabled = false
        field.contentType = .URL
        (field.cell as? NSTextFieldCell)?.allowedInputSourceLocales = [Locale.LanguageCode.english.identifier]
        field.cell?.sendsActionOnEndEditing = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("server-address")
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.confirm)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        field.font = font
        field.textColor = NSColor(ChirpTheme.ink)
        field.placeholderAttributedString = NSAttributedString(
            string: "chirp.example.com", attributes: [.font: font, .foregroundColor: NSColor(ChirpTheme.secondary)])
        field.setAccessibilityLabel(LocalizedMessage("服务器地址").localized(in: context.environment.locale))
        if field.stringValue != address { field.stringValue = address }
        if !context.environment.isEnabled, field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        field.isEnabled = context.environment.isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacServerAddressField
        init(_ parent: MacServerAddressField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.isEditing = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.isEditing = false }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.address = field.stringValue
        }
        @objc func confirm() { parent.submit() }
    }
}
#endif

struct LoginDeviceActions: View {
    @Environment(ApplicationSession.self) private var application
    let hasSavedIdentity: Bool
    let authorizeDevice: () -> Void
    let requestReset: () -> Void
    let showLogs: () -> Void

    var body: some View {
        VStack(spacing: ChirpTheme.Space.xs) {
            Divider().overlay(ChirpTheme.border)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ChirpTheme.Space.xl) { buttons }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: ChirpTheme.Space.xs) { buttons }
            }
        }
        .labelStyle(.titleAndIcon)
        #if os(macOS)
        .buttonStyle(.link)
        #else
        .buttonStyle(.plain)
        #endif
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: showLogs) { label("日志管理", systemImage: "doc.text") }
            .accessibilityIdentifier("log-settings-before-login")
        if hasSavedIdentity {
            Button(action: authorizeDevice) {
                label("授权新设备", systemImage: "qrcode.viewfinder")
            }
            .disabled(application.networkClock.status != .ready)
            .accessibilityIdentifier("authorize-device-before-login")
        }
        Button(role: .destructive, action: requestReset) {
            label("清空本地数据", systemImage: "trash")
        }
        .accessibilityIdentifier("clear-local-data-before-login")
    }

    private func label(_ title: LocalizedMessage, systemImage: String) -> some View {
        MessageLabel(title, systemImage: systemImage)
            .foregroundStyle(ChirpTheme.secondary)
            .padding(.horizontal, ChirpTheme.Space.xs)
            #if os(macOS)
            .font(.callout)
            .frame(minHeight: 28)
            #else
            .font(.footnote)
            .frame(minHeight: 44)
            #endif
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(.rect)
    }
}
