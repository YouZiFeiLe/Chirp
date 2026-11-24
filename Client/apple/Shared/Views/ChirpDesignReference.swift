#if DEBUG
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Offline fixtures for design review. These views never create a session or contact a server.
enum ChirpDesignSamples {
    static let members = [
        CallMember(id: "lin", name: "小林", microphoneEnabled: true, speaking: true, listening: true),
        CallMember(id: "alex", name: "Alex", microphoneEnabled: false, speaking: false, listening: false),
        CallMember(id: "yuan", name: "阿远", microphoneEnabled: true, speaking: false, listening: false),
        CallMember(id: "you", name: "柚子", microphoneEnabled: false, speaking: false, listening: true),
    ]
    static let rooms = [
        RoomOverview(roomID: "friends", displayName: "朋友客厅", description: "周五晚八点，一起听歌。", keyProtocol: VoiceRooms.keyProtocol,
                     maxParticipants: 0, participants: members.map { MemberInfo(id: $0.id, displayName: $0.name) },
                     mediaStatus: "available", passwordRequired: false),
        RoomOverview(roomID: "room-2", displayName: "一起专注", keyProtocol: VoiceRooms.keyProtocol,
                     maxParticipants: 0, participants: [], mediaStatus: "available", passwordRequired: true),
        RoomOverview(roomID: "room-3", displayName: "游戏小队", keyProtocol: VoiceRooms.keyProtocol,
                     maxParticipants: 0, participants: [], mediaStatus: "available", passwordRequired: false),
    ]
    static let messages = [
        ChatMessage(messageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, sender: "lin", senderName: "小林",
                    text: "晚上好，今天过得怎么样？", time: Date(timeIntervalSince1970: 0), delivery: .received),
        ChatMessage(messageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, sender: "you", senderName: "柚子",
                    text: "刚刚忙完，来听听大家的声音。", time: Date(timeIntervalSince1970: 60), delivery: .sent),
    ]
}

struct ChirpDesignReference: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                ChirpWordmark()
                Spacer()
                MessageText("视觉语言 / 01").font(.caption.monospaced()).foregroundStyle(ChirpTheme.secondary)
            }
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 24) {
                    RoomHeader(room: ChirpDesignSamples.rooms[0])
                    RoomIdentityStatusCard(trust: .solo)
                    Divider().overlay(ChirpTheme.border)
                    ChirpSectionHeading(title: "在这里", detail: "4")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(ChirpDesignSamples.members) { MemberCard(member: $0) }
                    }
                    RoomAudioSummary(title: "声音设置", detail: "Apple 系统处理", action: {})
                }
                .frame(width: 440)

                VStack(alignment: .leading, spacing: 20) {
                    ChirpSectionHeading(title: "房间列表")
                    ForEach(ChirpDesignSamples.rooms) { room in
                        RoomDirectoryCard(room: room, isFresh: true, isCurrent: room.roomID == "friends")
                    }
                    ChirpSectionHeading(title: "房间聊天", detail: "示例消息")
                        .padding(.top, 4)
                    ForEach(ChirpDesignSamples.messages) { message in
                        RoomChatMessageRow(message: message, isOwn: message.sender == "you")
                    }
                }
                .frame(width: 328)
            }
            Divider().overlay(ChirpTheme.border)
            HStack(spacing: 24) {
                swatch("画布", color: ChirpTheme.canvas)
                swatch("卡片", color: ChirpTheme.surface)
                swatch("强调", color: ChirpTheme.accent)
                swatch("正文", color: ChirpTheme.ink)
                Spacer()
                MessageText("原生 SwiftUI 组件 · 离线示例")
                    .font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
        }
        .padding(32)
        .background(ChirpTheme.canvas)
        .tint(ChirpTheme.accent)
    }

    private func swatch(_ title: LocalizedMessage, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 16, height: 16)
                .overlay { Circle().strokeBorder(ChirpTheme.border, lineWidth: 0.5) }
            MessageText(title).font(.caption).foregroundStyle(ChirpTheme.secondary)
        }
    }
}

struct ChirpDesignStateReference: View {
    private let unavailable = RoomOverview(roomID: "room-5", displayName: "和老朋友一起聊聊最近发生的事情",
        keyProtocol: VoiceRooms.keyProtocol, maxParticipants: 0, participants: nil,
        mediaStatus: "unavailable", passwordRequired: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ChirpSectionHeading(title: "窄屏与边界状态", detail: "320 pt / 示例数据")
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 24) {
                    RoomHeader(room: unavailable, status: "在线状态待同步")
                    RoomIdentityStatusCard(trust: .pending)
                    RoomDirectoryCard(room: unavailable, isFresh: false)
                    CallNotice(message: ClientFailure(.networkFailure))
                }
                .frame(width: 320)
                VStack(alignment: .leading, spacing: 24) {
                    RoomEmptyState(title: "林间还很安静", message: "房间里暂时还没有人。\n喊上朋友，或者先开麦试个音。")
                    RoomChatMessageRow(message: ChatMessage(
                        messageID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, sender: "you", senderName: "柚子",
                        text: "这是一条较长的示例消息，用来检查窄屏下的换行，以及未确认送达时的提示。",
                        time: Date(timeIntervalSince1970: 0), delivery: .failed), isOwn: true)
                }
                .frame(width: 320)
            }
        }
        .padding(28)
        .background(ChirpTheme.canvas)
    }
}

private struct ChirpDesignPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chirpDesignPreview: Bool {
        get { self[ChirpDesignPreviewKey.self] }
        set { self[ChirpDesignPreviewKey.self] = newValue }
    }
}

struct ProfileEditorSample {
    var name = "设计预览"
    var avatar: CGImage?
}

extension ProfileEditor {
    init(sample: Binding<ProfileEditorSample>) {
        let profile = sample.wrappedValue
        self.init(memberID: "design", savedName: profile.name, savedAvatar: profile.avatar, hasAvatar: profile.avatar != nil) { change in
            switch change {
            case .nickname(let name): sample.wrappedValue.name = name
            case .replaceAvatar(let data): sample.wrappedValue.avatar = AvatarImage.decoded(data)
            case .removeAvatar: sample.wrappedValue.avatar = nil
            }
        }
    }
}

/// Runs navigation and settings with an offline directory, sample time, and an in-memory identity.
struct ChirpDesignPreviewRoot: View {
    @State private var application = ApplicationSession(
        dependencies: .liveKit(identity: DeviceIdentityStore(persistence: MemoryIdentityPersistence())),
        networkClock: NetworkClock(query: { [NetworkTimeSample(utc: Date(), received: .now, roundTrip: .zero)] }))
    private var call: CallController { application.call }
    @StateObject private var directory = RoomDirectory.designPreview(
        rooms: ChirpDesignSamples.rooms)
    @State private var activeSheet: PreviewSheet?
    @State private var appearance = PreviewAppearance.system
    @State private var profile = ProfileEditorSample()

    private enum PreviewAppearance: String, CaseIterable {
        case system, light, dark
        var title: LocalizedMessage {
            switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
        }
        var colorScheme: ColorScheme? {
            switch self { case .system: nil; case .light: .light; case .dark: .dark }
        }
    }

    private enum PreviewSheet: Hashable, Identifiable {
        case audio, cache, components, profile, identity(IdentitySettingsPage)
        var id: Self { self }
    }

    var body: some View {
        Group {
            #if os(macOS)
            client
            .toolbar {
                ToolbarItem(placement: .principal) {
                    MessageText("离线设计预览 · 示例数据")
                        .font(.caption).foregroundStyle(ChirpTheme.secondary)
                }
                ToolbarItem { previewOptions }
            }
            #else
            VStack(spacing: 0) {
                HStack {
                    MessageText("设计预览 · 示例数据").font(.caption)
                    Spacer()
                    previewOptions
                }
                .dynamicTypeSize(...DynamicTypeSize.large)
                .padding(.horizontal, 16).padding(.vertical, 8).background(ChirpTheme.surfaceSubtle)
                client
            }
            #endif
        }
        .environment(\.chirpDesignPreview, true)
        .tint(ChirpTheme.accent)
        .preferredColorScheme(appearance.colorScheme)
        .sheet(item: $activeSheet) { sheet in
            Group {
                switch sheet {
                case .audio: AudioPresetSettingsView(call: call)
                case .cache: AttachmentCacheSettingsView()
                case .components: ChirpDesignReferenceSheet()
                case .profile: ProfileEditor(sample: $profile)
                case .identity(let page): IdentitySettingsView(page: page)
                }
            }
            .environment(\.chirpDesignPreview, true)
        }
        .environment(application)
        .environment(application.login)
        .task { await application.networkClock.check() }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 620)
        #endif
    }

    private var previewOptions: some View {
        Menu {
            LanguagePicker()
            Picker("外观", selection: $appearance) {
                ForEach(PreviewAppearance.allCases, id: \.self) { MessageText($0.title).tag($0) }
            }
            #if os(macOS)
            Menu("窗口尺寸") {
                Button("默认窗口") { resizePreview(width: 1120, height: 780) }
                Button("最小窗口") { resizePreview(width: 900, height: 620) }
            }
            #endif
            Divider()
            Button("组件参考") { activeSheet = .components }
        } label: { MessageLabel("预览选项", systemImage: "paintpalette") }
        .accessibilityIdentifier("design-preview-options")
    }

    #if os(macOS)
    private func resizePreview(width: CGFloat, height: CGFloat) {
        // Match screenshot window dimensions, respecting the content minimum plus system chrome.
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
        let size = NSSize(width: max(width, window.minSize.width), height: max(height, window.minSize.height))
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size.height,
                               width: size.width, height: size.height), display: true)
    }
    #endif

    private var client: some View {
        #if os(macOS)
        MacClientView(call: call, directory: directory, memberID: "design", memberName: profile.name, logout: {},
                      showProfileSettings: { activeSheet = .profile },
                      showAudioSettings: { activeSheet = .audio })
        #else
        IOSClientView(call: call, directory: directory, memberID: "design", memberName: profile.name, logout: {},
                      showProfileSettings: { activeSheet = .profile },
                      showCacheSettings: { activeSheet = .cache },
                      showIdentitySettings: { activeSheet = .identity($0) },
                      showAudioSettings: { activeSheet = .audio })
        #endif
    }
}

#if os(iOS)
/// Exercises the production attachment menu and system picker without a login or upload.
struct ChirpAttachmentPickerReference: View {
    @State private var showsPhotos = false
    @State private var showsFiles = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                MessageText("设计预览 · 示例数据").font(.caption).foregroundStyle(ChirpTheme.secondary)
                RoomAttachmentMenu(choosePhoto: { showsPhotos = true }, chooseFile: { showsFiles = true })
                    .tint(ChirpTheme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(ChirpTheme.canvas)
            .messageNavigationTitle("添加附件")
            .sheet(isPresented: $showsPhotos) { RoomPhotoPicker { _ in } }
            .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item]) { _ in }
        }
    }
}
#endif

private struct ChirpDesignReferenceSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) { ChirpDesignReference() }
                .messageNavigationTitle("组件参考")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
        }
        .frame(minWidth: 360, minHeight: 500)
        .tint(ChirpTheme.accent)
    }
}

#Preview("视觉语言 · 浅色") { ChirpDesignReference().preferredColorScheme(.light) }
#Preview("编辑个人资料") {
    @Previewable @State var profile = ProfileEditorSample()
    ProfileEditor(sample: $profile)
}
#Preview("视觉语言 · 深色") { ChirpDesignReference().preferredColorScheme(.dark) }
#Preview("窄屏与边界状态") { ChirpDesignStateReference() }
#Preview("空房间") {
    VStack(spacing: 16) {
        RoomIdentityStatusCard(trust: .solo)
        RoomEmptyState(title: "林间还很安静", message: "房间里暂时还没有人。")
    }
        .padding(24).frame(width: 360).background(ChirpTheme.canvas)
}
#Preview("长房间名与状态未同步") {
    RoomDirectoryCard(room: RoomOverview(roomID: "room-5", displayName: "和老朋友一起聊聊最近发生的事情",
        keyProtocol: VoiceRooms.keyProtocol, maxParticipants: 0, participants: nil,
        mediaStatus: "unavailable", passwordRequired: true), isFresh: false)
        .padding(24).frame(width: 360).background(ChirpTheme.canvas)
}
#endif
