#if os(macOS)
import SwiftUI

struct MacClientView: View {
    @Environment(\.locale) private var locale
    @Environment(\.roomIdentity) private var roomIdentity
    @ObservedObject var call: CallController
    @ObservedObject var directory: RoomDirectory
    let memberID: String
    let memberName: String
    let logout: () -> Void
    var showProfileSettings: () -> Void = {}
    let showAudioSettings: () -> Void
    @State private var selection: Destination?
    private enum Destination: Hashable { case room(String), friends }
    private var isFriends: Bool { selection == .friends }
    @State private var showsChat = true
    @State private var lastReadMessageID: String?

    private var selectedRoom: RoomOverview {
        if case .room(let id) = selection { return directory.room(id) }
        return directory.room(directory.defaultRoomID)
    }
    private var isCurrent: Bool { call.currentRoomID == selectedRoom.roomID }
    private var chatAvailable: Bool { call.showsChat(in: selectedRoom.roomID) }
    private var unreadCount: Int { showsChat && chatAvailable ? 0 : call.chat.unreadCount(after: lastReadMessageID) }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 252, max: 300)
        } detail: {
            Group {
                if isFriends { FriendsView() }
                else { roomLayout }
            }
            .messageNavigationTitle(isFriends ? "好友" : "语音空间")
            .toolbar { ToolbarItem(placement: .primaryAction) { settingsButton } }
        }
        .onChange(of: directory.rooms.map(\.roomID), initial: true) {
            if case .room(let id) = selection, !directory.rooms.contains(where: { $0.roomID == id }) {
                selection = .room(directory.defaultRoomID)
            } else if selection == nil { selection = .room(directory.defaultRoomID) }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(ChirpTheme.accent)
        .onChange(of: selection) {
            ClientLog.shared.record(.navigation, isFriends ? "friends" : "room")
        }
        .onChange(of: showsChat) { _, visible in
            ClientLog.shared.record(.navigation, visible ? "roomChat" : "roomMembers")
            if visible && chatAvailable { lastReadMessageID = call.chat.messages.last?.id }
        }
        .onChange(of: call.chat.messages.last?.id) { _, id in
            if !isFriends && showsChat && chatAvailable { lastReadMessageID = id }
        }
        .onChange(of: isFriends) { _, friends in
            if !friends && showsChat && chatAvailable { lastReadMessageID = call.chat.messages.last?.id }
        }
        .onChange(of: chatAvailable) { _, available in
            if !isFriends && available && showsChat { lastReadMessageID = call.chat.messages.last?.id }
            if !call.hasSession { lastReadMessageID = nil }
        }
    }

    private var roomLayout: some View {
        MacRoomChatLayout(isPresented: showsChat && chatAvailable) {
            roomDetail
        } chat: {
            if chatAvailable {
                RoomChatPanel(call: call)
                    .id(selectedRoom.roomID)
            }
        }
            .roomVerificationStatus(call: call, roomID: selectedRoom.roomID, identity: roomIdentity)
            .messageNavigationTitle("语音空间")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showsChat.toggle() } label: {
                        Label {
                            MessageText(unreadCount > 0 ? "房间聊天 · \(unreadCount) 条新消息" : "房间聊天")
                        } icon: {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .overlay(alignment: .topTrailing) {
                                    if unreadCount > 0 {
                                        Circle().fill(ChirpTheme.accent).frame(width: 6, height: 6).offset(x: 3, y: -3)
                                    }
                                }
                        }
                    }
                    .disabled(!chatAvailable)
                    .messageHelp("显示或隐藏房间聊天")
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .accessibilityIdentifier("toggle-room-chat")
                    .accessibilityAddTraits(showsChat && chatAvailable ? .isSelected : [])
                }
            }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label { MessageText("好友") } icon: { Image(systemName: "person.2") }
                    .padding(.vertical, 7)
                    .tag(Destination.friends)
                    .accessibilityIdentifier("main-friends")
            }
            Section("房间") {
                ForEach(directory.rooms) { room in
                    HStack(spacing: 12) {
                        Image(systemName: room.passwordRequired ? "lock" : "waveform")
                            .font(.body.weight(.medium))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(room.localizedDisplayName(in: locale)).font(.subheadline.weight(.medium)).lineLimit(1)
                            MessageText(call.currentRoomID == room.roomID ? "正在通话" : room.presenceDescription(isFresh: directory.isFresh))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    .tag(Destination.room(room.roomID))
                    .accessibilityIdentifier("voice-room-\(room.roomID)")
                    .messageAccessibilityValue(room.passwordRequired ? "密码房间" : "无密码房间")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                ChirpWordmark()
                MessageText("安全是不容妥协的底线")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                if call.hasSession || call.isBusy {
                    Button { selection = .room(call.currentRoomID ?? directory.defaultRoomID) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ConnectionStatusLabel(call: call)
                            Text(call.roomDisplayName).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .messageHelp("返回当前通话")
                    Divider()
                }
                Button(action: showProfileSettings) {
                    HStack(spacing: 10) {
                        IdentityAvatar(name: memberName, identity: memberID, size: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(memberName).font(.subheadline.weight(.semibold)).lineLimit(1)
                            MessageText("私人语音空间").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .messageHelp("编辑个人资料")
                .messageAccessibilityLabel("编辑个人资料")
            }
            .padding(20)
        }
    }

    private var settingsButton: some View {
        SettingsLink { MessageLabel("设置", systemImage: "gearshape") }
            .labelStyle(.titleAndIcon)
            .messageHelp("设置")
            .accessibilityIdentifier("client-settings")
    }

    private var roomDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ChirpTheme.Space.xxl) {
                RoomHeader(room: selectedRoom, status: isCurrent ? call.roomSummary : nil,
                           accessory: RoomPublicInformationView(call: call, room: selectedRoom))
                    .id(selectedRoom.roomID)
                if let message = call.errorMessage { CallNotice(message: message) }
                RoomMembersSection(call: call, room: selectedRoom, isFresh: directory.isFresh)
                if let message = directory.syncMessage {
                    MessageLabel(message, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(ChirpTheme.secondary)
                }
            }
            .frame(maxWidth: 800)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        // `.hidden` can still show a persistent scroller when a mouse is connected.
        // Keep wheel/trackpad and accessibility scrolling without a permanent gutter.
        .scrollIndicators(.never, axes: .vertical)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .safeAreaBar(edge: .bottom, alignment: .center, spacing: 0) {
            VStack(spacing: ChirpTheme.Space.sm) {
                callStatus
                CallControlsView(call: call, room: selectedRoom, showAudioSettings: showAudioSettings)
            }
            .padding(.horizontal, ChirpTheme.Space.lg)
            .padding(.top, ChirpTheme.Space.md)
            .padding(.bottom, ChirpTheme.Space.lg)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-room-content")
    }

    private var callStatus: some View {
        HStack(alignment: .firstTextBaseline, spacing: ChirpTheme.Space.sm) {
            if call.hasSession || call.isBusy || call.preparingRoomID != nil {
                ConnectionStatusLabel(call: call)
                MessageText(!isCurrent ? "正在与\(call.roomDisplayName)通话" : call.microphoneSummary)
                    .font(.caption).foregroundStyle(ChirpTheme.secondary)
            } else {
                MessageLabel("以静音状态加入", systemImage: "mic.slash")
                    .font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MacRoomCallActions: View {
    @ScaledMetric(relativeTo: .subheadline) private var preferredWidth: CGFloat = 352
    @ObservedObject var call: CallController
    let showAudioSettings: () -> Void

    var body: some View {
        let micAction: LocalizedMessage = call.isMuted ? "打开麦克风" : "关闭麦克风"
        let listenAction: LocalizedMessage = call.isListening ? "暂停收听" : "恢复收听"
        HStack(spacing: 4) {
            Button(action: call.toggleMute) {
                MessageLabel(micAction, systemImage: call.isMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(call.isMuted ? ChirpTheme.ink : ChirpTheme.accent)
            }
            .disabled(!call.canToggleMicrophone)
            .messageHelp(micAction)
            .messageAccessibilityLabel(micAction)
            .messageAccessibilityValue(call.microphoneSummary)
            .accessibilityIdentifier("toggle-microphone")
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Button(action: call.toggleListening) {
                MessageLabel("本机收听", systemImage: call.isListening ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .foregroundStyle(call.isListening ? ChirpTheme.accent : ChirpTheme.ink)
            }
            .messageHelp(listenAction)
            .messageAccessibilityLabel(listenAction)
            .messageAccessibilityValue(call.isListening ? "本机收听已开启" : "本机收听已暂停")
            .accessibilityIdentifier("toggle-call-listening")

            MacRoomAudioSettingsButton(preset: call.audioPreset, action: showAudioSettings)

            Divider().frame(height: 24).accessibilityHidden(true)

            Button(role: .destructive, action: call.leave) {
                MessageLabel("离开语音", systemImage: "phone.down.fill")
                    .foregroundStyle(ChirpTheme.danger)
            }
            .messageHelp("离开语音")
            .accessibilityIdentifier("leave-call")
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        .labelStyle(RoomCallLabelStyle())
        .buttonStyle(.borderless)
        .buttonBorderShape(.capsule)
        .buttonSizing(.flexible)
        .padding(.horizontal, ChirpTheme.Space.sm)
        .padding(.vertical, ChirpTheme.Space.xs)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: preferredWidth)
    }
}

private struct MacRoomAudioSettingsButton: View {
    let preset: AudioPreset
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                ViewThatFits(in: .horizontal) {
                    MessageText("声音设置").fixedSize(horizontal: true, vertical: false)
                    MessageText("声音")
                }
            } icon: {
                Image(systemName: "slider.horizontal.3")
            }
            .foregroundStyle(ChirpTheme.ink)
        }
        .messageHelp("声音设置")
        .messageAccessibilityLabel("声音设置")
        .messageAccessibilityValue(preset.shortTitle)
        .accessibilityIdentifier("audio-preset-settings")
    }
}
#endif
