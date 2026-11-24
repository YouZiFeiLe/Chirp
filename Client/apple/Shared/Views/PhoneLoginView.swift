#if os(macOS)
import CoreImage.CIFilterBuiltins
import SwiftUI

struct PhoneLoginView: View {
    @Environment(LoginSession.self) private var login
    @Environment(ApplicationSession.self) private var application
    @Environment(\.dismiss) private var dismiss
    @State private var attempt = UUID()
    @State private var authorization: ClientDeviceAuthorization?
    @State private var qrImage: CGImage?
    @State private var isLoading = true
    @State private var message: LocalizedMessage = "正在准备二维码…"
    @State private var failure: ClientFailure?
    @State private var api: ClientDeviceLoginAPI
    @State private var connection: ServerConnection

    init(connection: ServerConnection, identity: DeviceIdentityStore? = nil) {
        _connection = State(initialValue: connection)
        _api = State(initialValue: ClientDeviceLoginAPI(connection: connection, identity: identity))
    }

    var body: some View {
        VStack(spacing: 20) {
            RoomEmblem(size: 52)
            MessageLabel("手机扫码登录", systemImage: "qrcode.viewfinder")
                .font(.title2.weight(.semibold)).foregroundStyle(ChirpTheme.ink)
            MessageText("使用手机相机扫码，\n通过已登记的通行密钥确认登录。")
                .multilineTextAlignment(.center).foregroundStyle(ChirpTheme.secondary)

            if let qrImage, let authorization {
                Image(decorative: qrImage, scale: 1)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(18).background(.white, in: .rect(cornerRadius: 12))
                    .messageAccessibilityLabel("手机扫码登录二维码")
                    .accessibilityIdentifier("phone-login-code")
                Text(connection.passkeyOrigin.host ?? "").font(.callout.monospaced()).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    MessageText("二维码有效期剩余")
                    Text(timerInterval: min(Date.now, authorization.expiresAt)...authorization.expiresAt,
                         countsDown: true, showsHours: false)
                        .monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("phone-login-countdown")
            } else {
                Group {
                    if isLoading { ProgressView().controlSize(.large) }
                    else { Image(systemName: "qrcode").font(.system(size: 72)).foregroundStyle(.secondary) }
                }
                .frame(width: 256, height: 256)
            }

            Group {
                if let failure { FailureText(failure) }
                else { MessageText(message) }
            }
            .font(.callout).multilineTextAlignment(.center)
            .accessibilityIdentifier("phone-login-status")
            HStack(spacing: 14) {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("刷新二维码") { attempt = UUID() }
                    .disabled(isLoading).accessibilityIdentifier("refresh-phone-login")
            }
            .buttonStyle(.glass).controlSize(.large)
        }
        .padding(36).frame(width: 440)
        .background(ChirpTheme.canvas)
        .tint(ChirpTheme.accent)
        .logScreen("phoneLogin")
        .task(id: attempt) { await waitForLogin(attempt: attempt) }
    }

    @MainActor private func waitForLogin(attempt current: UUID) async {
        ClientLog.shared.record(.account, "phoneLogin", outcome: .started)
        let span = ClientLog.shared.begin()
        if let previous = authorization { await api.cancel(previous) }
        guard !Task.isCancelled, attempt == current else { return }
        authorization = nil
        qrImage = nil
        isLoading = true
        failure = nil
        message = "正在准备二维码…"
        do {
            try application.networkClock.requireReady()
            let refreshed = try await login.server.prepareConnection()
            try Task.checkCancellation()
            try application.networkClock.requireReady()
            guard attempt == current else { return }
            connection = refreshed
            let activeAPI = ClientDeviceLoginAPI(connection: refreshed, identity: application.identity)
            api = activeAPI
            let device = try await activeAPI.start()
            defer { Task { await activeAPI.cancel(device) } }
            try Task.checkCancellation()
            try application.networkClock.requireReady()
            guard attempt == current else { return }
            authorization = device
            qrImage = try makeQRCode(device.verificationURL)
            isLoading = false
            message = "等待手机确认，完成后会自动登录。"
            while Date() < device.expiresAt {
                do {
                    try application.networkClock.requireReady()
                    if let setup = try await activeAPI.pollIdentity(device) {
                        guard !Task.isCancelled, attempt == current, login.server.connection == refreshed, login.session == nil else { return }
                        try await application.identitySetup.begin(setup, connection: refreshed, verifier: device.verifier)
                        ClientLog.shared.finish(span, .account, "phoneLogin")
                        dismiss(); return
                    }
                    message = "等待手机确认，完成后会自动登录。"
                } catch let error as URLError where error.code != .cancelled {
                    message = "连接暂时中断，正在重试…"
                }
                try await Task.sleep(for: .seconds(min(device.interval, max(0.01, device.expiresAt.timeIntervalSinceNow))))
            }
            throw DeviceLoginError.expired
        } catch is CancellationError {
            ClientLog.shared.finish(span, .account, "phoneLogin", error: CancellationError())
            return
        } catch let error as URLError where error.code == .cancelled {
            ClientLog.shared.finish(span, .account, "phoneLogin", error: error)
            return
        } catch {
            ClientLog.shared.finish(span, .account, "phoneLogin", error: error)
            guard !Task.isCancelled, attempt == current else { return }
            qrImage = nil
            isLoading = false
            failure = ClientFailure.capture(error, fallback: .loginIncomplete)
        }
    }

    private func makeQRCode(_ url: URL) throws -> CGImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let output = CIContext().createCGImage(image, from: image.extent) else {
            throw ClientFailure(.qrGenerationFailed)
        }
        return output
    }
}
#endif
