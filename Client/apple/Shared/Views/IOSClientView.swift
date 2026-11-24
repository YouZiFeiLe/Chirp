#if os(iOS)
import SwiftUI

struct IOSClientView: View {
    @ObservedObject var call: CallController
    @ObservedObject var directory: RoomDirectory
    let memberID: String
    let memberName: String
    let logout: () -> Void
    var showProfileSettings: () -> Void = {}
    var showCacheSettings: () -> Void = {}
    var showLogSettings: () -> Void = {}
    var showIdentitySettings: (IdentitySettingsPage) -> Void = { _ in }
    let showAudioSettings: () -> Void
    @State private var selectedTab = ClientTab.voice
    @State private var voicePath: [RoomRoute] = []

    private enum ClientTab { case voice, friends, settings }
    private enum RoomRoute: Hashable { case room(String) }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("房间", systemImage: "waveform", value: .voice) {
                NavigationStack(path: $voicePath) {
                    roomList
                        .navigationDestination(for: RoomRoute.self) { route in
                            switch route {
                            case let .room(id):
                                IOSRoomView(call: call, directory: directory, roomID: id,
                                            showAudioSettings: showAudioSettings)
                            }
                        }
                }
            }
            Tab("好友", systemImage: "person.2", value: .friends) {
                FriendsView()
            }
            Tab("我的", systemImage: "person.crop.circle", value: .settings) {
                NavigationStack { settingsList }
            }
        }
        .onChange(of: selectedTab, initial: true) {
            switch selectedTab {
            case .voice: ClientLog.shared.record(.navigation, "rooms")
            case .friends: ClientLog.shared.record(.navigation, "friends")
            case .settings: ClientLog.shared.record(.navigation, "settings")
            }
        }
        .onChange(of: directory.rooms.map(\.roomID)) {
            voicePath.removeAll { route in
                switch route { case .room(let id): !directory.rooms.contains(where: { $0.roomID == id }) }
            }
        }
        .tint(ChirpTheme.accent)
        .tabViewBottomAccessory(isEnabled: (call.hasSession || call.isBusy) && (selectedTab != .voice || voicePath.isEmpty)) {
            Button {
                selectedTab = .voice
                voicePath = [.room(call.currentRoomID ?? directory.defaultRoomID)]
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "waveform").foregroundStyle(ChirpTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(call.roomDisplayName).font(.subheadline.weight(.semibold))
                        MessageText(call.status).font(.caption).foregroundStyle(ChirpTheme.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up").font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .messageAccessibilityLabel("返回\(call.roomDisplayName)，\(call.status)")
            .accessibilityIdentifier("return-to-call")
        }
    }

    private var roomList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    ChirpEyebrow(title: "你的语音空间")
                    MessageText("和朋友，畅所欲言。")
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .tracking(-0.8).foregroundStyle(ChirpTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    MessageText("在这里，没有言多必失，只有言无不尽。")
                        .font(.subheadline).foregroundStyle(ChirpTheme.secondary)
                }
                .padding(.vertical, 16)

                ChirpSectionHeading(title: "房间", detail: "\(directory.rooms.count) 个房间")

                LazyVStack(spacing: 12) {
                    ForEach(directory.rooms) { room in
                        NavigationLink(value: RoomRoute.room(room.roomID)) {
                            RoomDirectoryCard(room: room, isFresh: directory.isFresh,
                                              isCurrent: call.currentRoomID == room.roomID)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("voice-room-\(room.roomID)")
                    }
                }
                if let message = directory.syncMessage {
                    MessageLabel(message, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(ChirpTheme.secondary)
                }
                MessageLabel("安全是不容妥协的底线", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(ChirpTheme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .background(ChirpTheme.canvas)
        .messageNavigationTitle("房间")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { ChirpWordmark(compact: true).fixedSize() }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                Button("我的账号与设置", systemImage: "person.crop.circle") { selectedTab = .settings }
                .labelStyle(.iconOnly)
                .messageAccessibilityLabel("我的账号与设置")
                .accessibilityIdentifier("open-account-settings")
            }
        }
    }

    private var settingsList: some View {
        ClientSettingsView(call: call, memberID: memberID, memberName: memberName, logout: logout,
            showProfileSettings: showProfileSettings, showCacheSettings: showCacheSettings, showLogSettings: showLogSettings,
            showIdentitySettings: showIdentitySettings, showAudioSettings: showAudioSettings)
    }
}
#endif
