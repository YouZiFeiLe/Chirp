import LocalAuthentication
import SwiftUI

/// Wrap the presenting view itself so its sheets, popovers and accessibility
/// elements leave the hierarchy along with the account UI.
struct LoginGate: ViewModifier {
    @Environment(LoginSession.self) private var login
    #if os(iOS)
    @Environment(\.scenePhase) private var phase
    @State private var snapshotCovers: [UIView] = []
    #endif

    func body(content: Content) -> some View {
        Group {
            if login.isLocked {
                LoginLockView(biometry: unlockBiometry, isUnlocking: login.isUnlocking, failure: login.unlockFailure,
                              unlock: login.unlock, usePasskey: { Task { await login.logout() } })
            } else {
                content
            }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // UIKit may snapshot a presented sheet before SwiftUI renders the background phase.
            guard login.session != nil, snapshotCovers.isEmpty else { return }
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows where window.windowLevel == .normal && !window.isHidden {
                    let cover = UIView(frame: window.bounds)
                    cover.backgroundColor = .systemBackground
                    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    window.addSubview(cover)
                    snapshotCovers.append(cover)
                }
            }
        }
        .onChange(of: phase, initial: true) {
            guard phase == .active else { return }
            snapshotCovers.forEach { $0.removeFromSuperview() }
            snapshotCovers.removeAll()
        }
        #endif
    }

    private var unlockBiometry: LABiometryType {
        if let biometry = LAEnvironment.currentUser.state.biometry, biometry.isUsable {
            return biometry.biometryType
        }
        return .none
    }
}

struct LoginLockView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let biometry: LABiometryType
    let isUnlocking: Bool
    let failure: ClientFailure?
    let unlock: () -> Void
    let usePasskey: () -> Void

    var body: some View {
        #if os(macOS)
        GeometryReader { window in
            panel(compact: window.size.height < 520)
        }
        #else
        panel(compact: false)
        #endif
    }

    private func panel(compact: Bool) -> some View {
        ScrollView {
            VStack(spacing: compact ? ChirpTheme.Space.xl : ChirpTheme.Space.section) {
                welcome(compact: compact)

                VStack(spacing: ChirpTheme.Space.sm) {
                    if let failure {
                        Label {
                            FailureText(failure)
                        } icon: {
                            Image(systemName: "exclamationmark.circle")
                        }
                        .font(.callout)
                        .foregroundStyle(ChirpTheme.danger)
                        .multilineTextAlignment(.leading)
                        .padding(.bottom, ChirpTheme.Space.sm)
                    }

                    unlockButton

                    Button(action: usePasskey) {
                        MessageText("改用通行密钥登录")
                            #if os(macOS)
                            .font(.body.weight(.medium))
                            #else
                            .font(.subheadline.weight(.medium))
                            #endif
                            .foregroundStyle(ChirpTheme.accent)
                            .padding(.horizontal, ChirpTheme.Space.lg)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    #if os(macOS)
                    .buttonStyle(.link)
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .accessibilityIdentifier("discard-saved-login")
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 336)
            #if os(macOS)
            .chirpSurface(padding: compact ? ChirpTheme.Space.xl : ChirpTheme.Space.section, cornerRadius: ChirpTheme.Radius.hero)
            #endif
            .padding(ChirpTheme.Space.xl)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
        .background(ChirpTheme.canvas)
        .tint(ChirpTheme.accent)
    }

    private func welcome(compact: Bool) -> some View {
        let smallEmblem = compact || dynamicTypeSize.isAccessibilitySize
        return VStack(spacing: compact ? ChirpTheme.Space.lg : ChirpTheme.Space.xl) {
            QuietWave(size: smallEmblem ? 80 : 144)
                .background(Circle().fill(ChirpTheme.hero.opacity(0.55)).padding(5))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChirpTheme.onAccent)
                        .frame(width: 32, height: 32)
                        .background(ChirpTheme.accent, in: .circle)
                        .overlay { Circle().strokeBorder(ChirpTheme.canvas, lineWidth: 3) }
                        .padding(smallEmblem ? 0 : 12)
                }
                .accessibilityHidden(true)

            VStack(spacing: ChirpTheme.Space.sm) {
                MessageText("欢迎回来")
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .foregroundStyle(ChirpTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                MessageText(unlockInstructions)
                    #if os(macOS)
                    .font(.title3)
                    #else
                    .font(.body)
                    #endif
                    .foregroundStyle(ChirpTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var unlockInstructions: LocalizedMessage {
        #if os(macOS)
        biometry == .touchID ? "使用触控 ID 或 Mac 登录密码继续。" : "使用 Mac 登录密码继续。"
        #else
        "验证身份，继续使用 Chirp。"
        #endif
    }

    private var unlockButton: some View {
        Button(action: unlock) {
            ZStack {
                unlockLabel.opacity(isUnlocking ? 0 : 1)
                    .accessibilityHidden(isUnlocking)
                if isUnlocking {
                    HStack(spacing: ChirpTheme.Space.sm) {
                        ProgressView().controlSize(.small).tint(ChirpTheme.accent).accessibilityHidden(true)
                        MessageText("正在解锁")
                    }
                }
            }
        }
        .buttonStyle(UnlockButtonStyle(isUnlocking: isUnlocking))
        #if os(macOS)
        .keyboardShortcut(.defaultAction)
        #endif
        .disabled(isUnlocking)
        .accessibilityIdentifier("unlock-login")
    }

    @ViewBuilder private var unlockLabel: some View {
        #if os(macOS)
        // The system offers the account password even when Touch ID is available.
        MessageLabel("解锁 Chirp", systemImage: biometry == .touchID ? "touchid" : "lock.open")
        #else
        switch biometry {
        case .faceID: MessageLabel("使用面容 ID 解锁", systemImage: "faceid")
        case .touchID: MessageLabel("使用触控 ID 解锁", systemImage: "touchid")
        default: MessageLabel("解锁 Chirp", systemImage: "lock.open")
        }
        #endif
    }
}

private struct UnlockButtonStyle: ButtonStyle {
    let isUnlocking: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            #if os(macOS)
            .font(.title3.weight(.semibold))
            #else
            .font(.headline)
            #endif
            .foregroundStyle(isUnlocking ? ChirpTheme.accent : ChirpTheme.onAccent)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, ChirpTheme.Space.lg)
            .padding(.vertical, ChirpTheme.Space.md)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(isUnlocking ? ChirpTheme.surfaceSubtle : ChirpTheme.accent,
                        in: .rect(cornerRadius: ChirpTheme.Radius.control))
            .contentShape(.rect(cornerRadius: ChirpTheme.Radius.control))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}
