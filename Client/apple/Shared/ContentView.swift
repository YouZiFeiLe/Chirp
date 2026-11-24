import SwiftUI

struct ContentView: View {
    @Environment(LoginSession.self) private var login
    @Environment(ApplicationSession.self) private var application
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var call: CallController
    @State private var windowID = UUID()
    @State private var activeSheet: SettingsSheet?
    @State private var resetConfirmation = false
    private var directory: RoomDirectory { application.directory }

    private enum SettingsSheet: Identifiable, Equatable {
        case audio, profile, cache, logs, identity(IdentitySettingsPage)
        var id: String {
            switch self {
            case .audio: "audio"
            case .profile: "profile"
            case .cache: "cache"
            case .logs: "logs"
            case .identity(let page): "identity-" + page.rawValue
            }
        }
        var isIdentity: Bool { if case .identity = self { true } else { false } }
    }

    var body: some View {
        Group {
            if let session = login.session {
                client(member: session.member)
            } else { loginScreen }
        }
        .sheet(item: Binding(get: { application.roomIdentity.verificationPresentation }, set: { if $0 == nil { application.roomIdentity.dismissVerification() } })) { presentation in
            SASVerificationView(room: application.roomIdentity, peer: presentation.peer)
        }
        .environment(\.roomIdentity, application.roomIdentity)
        .task(id: scenePhase) {
            if scenePhase == .active { await application.networkClock.monitor() }
        }
        .onChange(of: application.networkClock.status == .ready) {
            if application.networkClock.status != .ready, application.identitySetup.authentication != nil {
                application.identitySetup.cancel()
            }
        }
        .onChange(of: login.session?.credential, initial: true) {
            if activeSheet != .logs && activeSheet?.isIdentity != true { activeSheet = nil }
        }
        .onChange(of: scenePhase, initial: true) {
            application.stateSync.setVisible(windowID, scenePhase == .active)
            switch scenePhase {
            case .active:
                ClientLog.shared.maintain()
                ClientLog.shared.record(.application, "active")
                Task { await application.social.refresh() }
            case .background:
                ClientLog.shared.record(.application, "background")
                ClientLog.shared.flushSoon()
            case .inactive: ClientLog.shared.record(.application, "inactive")
            @unknown default: break
            }
        }
        .onAppear { application.stateSync.setVisible(windowID, scenePhase == .active) }
        .onDisappear { application.stateSync.setVisible(windowID, false) }
        .onChange(of: login.profiles.names, initial: true) { call.updateProfileNames(login.profiles.names) }
        .onChange(of: application.identity.revision) { call.refreshVerifiedNames() }
        .onReceive(directory.$rooms) { rooms in
            call.updateRoomNames(rooms)
            if directory.isFresh, let id = call.currentRoomID, !rooms.contains(where: { $0.roomID == id }) { call.leave() }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .audio: AudioPresetSettingsView(call: call)
            case .profile: ProfileEditView()
            case .cache: AttachmentCacheSettingsView()
            case .logs: LogManagementView()
            case .identity(let page): IdentitySettingsView(page: page)
            }
        }
        .sheet(isPresented: Binding(get: { application.identitySetup.isPresented }, set: { _ in })) { IdentitySetupView(setup: application.identitySetup) }
        .tint(ChirpTheme.accent)
        .environment(\.memberProfiles, login.profiles)
    }

    private var loginScreen: some View {
        LoginView(localActions: LoginDeviceActions(
            hasSavedIdentity: !application.identity.savedScopes.isEmpty,
            authorizeDevice: { if application.networkClock.isReadyNow() { activeSheet = .identity(.authorizeDevice) } },
            requestReset: { resetConfirmation = true },
            showLogs: { activeSheet = .logs }
        ))
        .modifier(LocalDataResetConfirmation(isPresented: $resetConfirmation))
    }

    private func logout() {
        call.leave()
        Task { await login.logout() }
    }

    private func client(member: MemberInfo) -> some View {
        Group {
            #if os(macOS)
            MacClientView(call: call, directory: directory, memberID: member.id,
                          memberName: login.profiles.displayName(for: member.id, fallback: member.displayName), logout: logout,
                          showProfileSettings: { activeSheet = .profile },
                          showAudioSettings: { activeSheet = .audio })
                .frame(minWidth: 900, minHeight: 620)
            #else
            IOSClientView(call: call, directory: directory, memberID: member.id,
                          memberName: login.profiles.displayName(for: member.id, fallback: member.displayName), logout: logout,
                          showProfileSettings: { activeSheet = .profile },
                          showCacheSettings: { activeSheet = .cache },
                          showLogSettings: { activeSheet = .logs },
                          showIdentitySettings: { activeSheet = .identity($0) },
                          showAudioSettings: { activeSheet = .audio })
            #endif
        }
    }
}

extension View {
    func logScreen(_ name: StaticString) -> some View {
        onAppear { ClientLog.shared.record(.navigation, name, details: .screen(visible: true)) }
            .onDisappear { ClientLog.shared.record(.navigation, name, details: .screen(visible: false)) }
    }
}

#Preview {
    let application = ApplicationSession()
    ContentView().environment(application).environment(application.login).environmentObject(application.call)
}
