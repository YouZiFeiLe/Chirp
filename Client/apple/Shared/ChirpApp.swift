import LiveKit
import SwiftUI

#if os(macOS)
import AppKit

@MainActor
final class ChirpAppDelegate: NSObject, NSApplicationDelegate {
    weak var call: CallController?
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
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }

        // 从当前应用包显式设置运行时图标，刷新 Dock 显示。
        NSApplication.shared.applicationIconImage = icon
    }
}
#endif

@main
struct ChirpApp: App {
    @State private var application: ApplicationSession
    #if os(macOS)
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
            .environmentObject(application.call)
            .environment(application)
            .environment(application.login)
            #if os(macOS)
            .onAppear { appDelegate.call = application.call }
            #endif
            .withAppLanguage()
        }
        #if os(macOS)
        .defaultSize(width: ProcessInfo.processInfo.arguments.contains("--identity-setup-preview") ? 640 :
            (ProcessInfo.processInfo.arguments.contains("--audio-settings-preview") || ProcessInfo.processInfo.arguments.contains("--device-verification-preview") ? 600 : 1120), height: 780)
        #endif
        #if os(macOS)
        Settings {
            MacSettingsView()
                #if DEBUG
                .environment(\.chirpDesignPreview, ProcessInfo.processInfo.arguments.contains("--design-preview"))
                #endif
                .environment(application)
                .environment(application.login)
                .environment(\.memberProfiles, application.login.profiles)
                .withAppLanguage()
        }
        #endif
    }
}
