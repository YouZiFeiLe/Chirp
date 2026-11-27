import LiveKit
import SwiftUI

#if os(macOS)
import AppKit

@MainActor
final class ChirpAppDelegate: NSObject, NSApplicationDelegate {
    weak var call: CallController?
    weak var login: LoginSession?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard let call, call.hasPendingWork else { return .terminateNow }
        terminating = true
        Task { @MainActor in
            await call.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClientLog.shared.record(.application, "terminate")
        ClientLog.shared.flushAtExit()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let windows = NotificationCenter.default
        windows.addObserver(self, selector: #selector(windowLeaving), name: NSWindow.willCloseNotification, object: nil)
        windows.addObserver(self, selector: #selector(windowLeaving), name: NSWindow.didMiniaturizeNotification, object: nil)
        windows.addObserver(self, selector: #selector(windowAvailable), name: NSWindow.didBecomeKeyNotification, object: nil)
        windows.addObserver(self, selector: #selector(windowAvailable), name: NSWindow.didDeminiaturizeNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(leftForeground), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(leftForeground), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(windowAvailable), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(windowAvailable), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(otherAppActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }

        // 从当前应用包显式设置运行时图标，刷新 Dock 显示。
        NSApplication.shared.applicationIconImage = icon
    }

    func applicationDidResignActive(_ notification: Notification) {
        // The system authentication panel can temporarily take focus itself.
        if !LocalAuthenticationPrompt.isPresented { login?.leaveForeground() }
    }

    func applicationDidHide(_ notification: Notification) { login?.leaveForeground() }
    func applicationDidBecomeActive(_ notification: Notification) { windowAvailable(notification) }

    @objc private func leftForeground(_ note: Notification) { login?.leaveForeground() }

    @objc private func otherAppActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app != .current, app.activationPolicy == .regular else { return }
        login?.leaveForeground()
    }

    @objc func windowAvailable(_ note: Notification? = nil) {
        if NSApp.isActive, NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized }) {
            login?.enterForeground()
        }
    }

    @objc private func windowLeaving(_ note: Notification) {
        guard let leaving = note.object as? NSWindow, leaving.canBecomeMain,
              !NSApp.windows.contains(where: { $0 !== leaving && $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized }) else { return }
        login?.leaveForeground()
    }
}
#endif

@main
struct ChirpApp: App {
    @State private var application: ApplicationSession
    #if os(iOS)
    @Environment(\.scenePhase) private var phase
    #else
    @NSApplicationDelegateAdaptor(ChirpAppDelegate.self) private var appDelegate
    #endif

    init() {
        // SDK messages may contain addresses or identities. Capture only the typed app events.
        LiveKitSDK.disableLogging()
        ClientLog.shared.start()
        _application = State(initialValue: ApplicationSession())
        SavedConnection.discardRetiredRoomKeys()
        _ = AttachmentCache.shared
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--room-information-preview") {
                    RoomInformationPreview()
                } else if ProcessInfo.processInfo.arguments.contains("--device-verification-preview") {
                    SASVerificationPreview()
                } else if ProcessInfo.processInfo.arguments.contains("--identity-setup-preview") {
                    IdentitySetupPreview(
                        step: ProcessInfo.processInfo.arguments.contains("--recovery-authorize") ? .authorize :
                            (ProcessInfo.processInfo.arguments.contains("--recovery-confirmation") ? .confirmation : .password),
                        saved: ProcessInfo.processInfo.arguments.contains("--recovery-saved"))
                        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--recovery-dark") ? .dark : .light)
                } else if ProcessInfo.processInfo.arguments.contains("--audio-settings-preview") {
                    AudioPresetSettingsView(call: application.call)
                } else if ProcessInfo.processInfo.arguments.contains("--attachment-transfer-preview") {
                    AttachmentTransferReference()
                } else {
                    #if os(iOS)
                    if ProcessInfo.processInfo.arguments.contains("--attachment-picker-preview") {
                        ChirpAttachmentPickerReference()
                    } else if ProcessInfo.processInfo.arguments.contains("--design-preview") {
                        ChirpDesignPreviewRoot()
                    } else {
                        ContentView().environment(application.login)
                }
                #else
                if ProcessInfo.processInfo.arguments.contains("--design-preview") {
                    ChirpDesignPreviewRoot()
                } else {
                    ContentView().environment(application.login)
                }
                #endif
                }
                #else
                ContentView().environment(application.login)
                #endif
            }
            .modifier(LoginGate())
            .environmentObject(application.call)
            .environment(application)
            .environment(application.login)
            #if os(macOS)
            .onAppear { attachDelegate() }
            #endif
            .withAppLanguage()
        }
        #if os(iOS)
        .onChange(of: phase, initial: true) {
            switch phase {
            case .active: application.login.enterForeground()
            case .background: application.login.leaveForeground()
            default: break
            }
        }
        #else
        .defaultSize(width: ProcessInfo.processInfo.arguments.contains("--identity-setup-preview") ? 640 :
            (ProcessInfo.processInfo.arguments.contains("--audio-settings-preview") || ProcessInfo.processInfo.arguments.contains("--device-verification-preview") ? 600 : 1120), height: 780)
        #endif
        #if os(macOS)
        Settings {
            MacSettingsView()
                #if DEBUG
                .environment(\.chirpDesignPreview, ProcessInfo.processInfo.arguments.contains("--design-preview"))
                #endif
                .modifier(LoginGate())
                .onAppear { attachDelegate() }
                .environment(application)
                .environment(application.login)
                .environment(\.memberProfiles, application.login.profiles)
                .withAppLanguage()
        }
        #endif
    }

    #if os(macOS)
    private func attachDelegate() {
        appDelegate.call = application.call
        appDelegate.login = application.login
        appDelegate.windowAvailable()
    }
    #endif
}
