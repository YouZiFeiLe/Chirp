import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import PhotosUI
#endif

extension View {
    @ViewBuilder func roomActionTarget() -> some View {
        #if os(iOS)
        self.frame(minHeight: 44)
        #else
        self
        #endif
    }
}

extension RoomChat {
    func unreadCount(after messageID: String?) -> Int {
        guard let messageID, let index = messages.firstIndex(where: { $0.id == messageID }) else { return messages.count }
        return messages.count - index - 1
    }
}

struct RoomChatMessageRow: View, Equatable {
    let message: ChatMessage
    let isOwn: Bool
    var attachments: RoomAttachmentController? = nil
    var canRestore = false
    var restore: (() -> Void)? = nil

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.isOwn == rhs.isOwn && lhs.canRestore == rhs.canRestore
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if isOwn { Spacer(minLength: 28) }
            if !isOwn { IdentityAvatar(name: message.senderName, identity: message.sender, size: 28) }
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Group {
                        if isOwn { MessageText("你") }
                        else { Text(verbatim: message.senderName) }
                    }
                        .font(.caption.weight(.medium))
                    Text(message.time, style: .time).font(.caption2)
                }
                .foregroundStyle(ChirpTheme.secondary)
                if let info = message.attachment, let attachments {
                    RoomAttachmentRow(info: info, attachments: attachments)
                } else {
                    Text(verbatim: message.text)
                        .font(.body).foregroundStyle(ChirpTheme.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, 13).padding(.vertical, 10)
                        .background(isOwn ? ChirpTheme.surfaceSubtle : ChirpTheme.surface,
                                    in: .rect(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(ChirpTheme.border.opacity(0.6), lineWidth: 0.5)
                        }
                }
                if message.delivery == .sending {
                    ProgressView().controlSize(.mini).messageAccessibilityLabel("正在发送")
                } else if message.delivery == .failed {
                    MessageLabel("发送未提交", systemImage: "exclamationmark.circle")
                        .font(.caption2).foregroundStyle(ChirpTheme.warning)
                    if message.attachment == nil, isOwn, let restore {
                        Button(action: restore) { MessageLabel("放回草稿", systemImage: "arrow.uturn.backward").roomActionTarget() }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(!canRestore)
                            .messageAccessibilityHint("仅放回当前房间的空草稿，不会自动发送")
                    }
                } else if message.delivery == .sent {
                    MessageText("已提交发送").font(.caption2).foregroundStyle(ChirpTheme.secondary)
                }
            }
            .frame(maxWidth: 480, alignment: isOwn ? .trailing : .leading)
            if !isOwn { Spacer(minLength: 28) }
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
        .privacySensitive()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-chat-message")
    }
}

struct RoomChatComposer: View {
    @Environment(\.roomNeedsVerification) private var needsVerification
    @ObservedObject var call: CallController
    @ObservedObject private var attachments: RoomAttachmentController
    init(call: CallController) { self.call = call; self.attachments = call.attachments }
    @State private var showsAttachmentPicker = false
    @State private var pickerEntryID: String?
    @State private var pickerRevision: UUID?
    #if os(iOS)
    @State private var photoPicker: RoomPhotoPickerContext?
    #endif

    private var inputBackground: Color {
        #if os(macOS)
        ChirpTheme.chatInput
        #else
        ChirpTheme.surfaceSubtle
        #endif
    }

    #if os(macOS)
    private func handleReturn(_ key: KeyPress) -> KeyPress.Result {
        guard key.modifiers.contains(.shift),
              let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              !editor.hasMarkedText() else { return .ignored }
        // Handle Shift-Return before the field commits and changes its selection.
        editor.insertNewlineIgnoringFieldEditor(nil)
        return .handled
    }

    private func submit() {
        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        // Let the input method finish composing before sending a message.
        guard editor?.hasMarkedText() != true else { return }
        guard NSApp.currentEvent?.modifierFlags.contains(.shift) != true else { return }
        guard call.canSendChat else { return }
        call.sendChat()
    }
    #endif

    var body: some View {
        let entryID = call.chat.admission?.entryID
        VStack(alignment: .leading, spacing: 6) {
            if !call.chat.isReady || !call.isConnected {
                MessageLabel(needsVerification ? "完成设备互认后才能发送" : "安全连接更新中，暂时无法发送",
                             systemImage: needsVerification ? "exclamationmark.shield" : "lock.rotation")
                    .font(.caption).foregroundStyle(needsVerification ? ChirpTheme.roomVerificationInk : ChirpTheme.secondary)
            }
            if let error = call.chat.error {
                FailureText(error).font(.caption).foregroundStyle(ChirpTheme.warning)
            }
            AttachmentComposerStatus(attachments: attachments)
            HStack(alignment: .bottom, spacing: 10) {
                #if os(iOS)
                RoomAttachmentMenu {
                    guard let entryID = call.chat.admission?.entryID else { return }
                    photoPicker = RoomPhotoPickerContext(entryID: entryID, revision: attachments.revision)
                } chooseFile: {
                    pickerEntryID = call.chat.admission?.entryID
                    pickerRevision = attachments.revision
                    showsAttachmentPicker = true
                }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(!call.canSendAttachment || attachments.isSending)
                #else
                Button {
                    pickerEntryID = call.chat.admission?.entryID
                    pickerRevision = attachments.revision
                    showsAttachmentPicker = true
                } label: { MessageLabel("发送图片或文件", systemImage: "paperclip") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .frame(minWidth: 32, minHeight: 44)
                    .disabled(!call.canSendAttachment || call.attachments.isSending)
                    .messageHelp("发送图片或文件")
                    .accessibilityIdentifier("room-chat-attach")
                #endif
                TextField("发条消息…", text: Binding(
                    get: { call.chat.admission?.entryID == entryID ? call.chat.draft : "" },
                    set: { call.setChatDraft($0, entryID: entryID) }), axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(inputBackground, in: .rect(cornerRadius: 16))
                    #if os(macOS)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(ChirpTheme.border.opacity(0.8), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    #endif
                    .autocorrectionDisabled()
                    .disabled(!call.chat.isReady || !call.isConnected)
                    #if os(macOS)
                    .onKeyPress(.return, phases: .down, action: handleReturn)
                    .onSubmit(submit)
                    .messageHelp("回车发送，Shift＋回车换行")
                    #endif
                    .accessibilityIdentifier("room-chat-composer")
                Button(action: call.sendChat) {
                    MessageLabel("发送", systemImage: "arrow.up")
                        .font(.body.weight(.semibold))
                        #if os(macOS)
                        .frame(width: 28, height: 30)
                        #else
                        .frame(minWidth: 32, minHeight: 32)
                        #endif
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                #if os(macOS)
                .controlSize(.large)
                #else
                .controlSize(.regular)
                .frame(minWidth: 44, minHeight: 44)
                #endif
                .tint(ChirpTheme.accent)
                .disabled(!call.canSendChat)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("room-chat-send")
            }
            MessageText("离开房间后将自动清空聊天记录")
                .font(.caption2).foregroundStyle(ChirpTheme.secondary)
        }
        .fileImporter(isPresented: $showsAttachmentPicker, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result, pickerEntryID == call.chat.admission?.entryID,
               pickerRevision == attachments.revision, call.canSendAttachment {
                call.attachments.send(source: url)
            }
        }
        #if os(iOS)
        .sheet(item: $photoPicker) { context in
            RoomPhotoPicker { photo in
                guard context.entryID == call.chat.admission?.entryID,
                      context.revision == attachments.revision, call.canSendAttachment else { return }
                attachments.send(photo: photo)
            }
        }
        #endif
        .onChange(of: call.chat.admission?.entryID) { dismissPickers() }
        .onChange(of: attachments.revision) { dismissPickers() }
        .background { AttachmentPreviewPresenter(attachments: call.attachments) }
        .privacySensitive()
    }

    private func dismissPickers() {
        showsAttachmentPicker = false; pickerEntryID = nil; pickerRevision = nil
        #if os(iOS)
        photoPicker = nil
        #endif
    }
}

#if os(iOS)
struct RoomAttachmentMenu: View {
    let choosePhoto: () -> Void
    let chooseFile: () -> Void

    var body: some View {
        Menu {
            Button("从照片选择", systemImage: "photo.on.rectangle", action: choosePhoto)
                .accessibilityIdentifier("room-chat-choose-photo")
            Button("选择文件", systemImage: "doc", action: chooseFile)
                .accessibilityIdentifier("room-chat-choose-file")
        } label: {
            MessageLabel("添加附件", systemImage: "plus")
                .font(.body.weight(.medium)).frame(width: 44, height: 44)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("room-chat-attach")
    }
}

private struct RoomPhotoPickerContext: Identifiable {
    let id = UUID()
    let entryID: String
    let revision: UUID
}

/// PHPicker grants access to the selected image only; no library-wide authorization.
struct RoomPhotoPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (AttachmentPhotoSource) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect, dismiss: dismiss) }

    @MainActor final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelect: (AttachmentPhotoSource) -> Void
        let dismiss: DismissAction
        init(onSelect: @escaping (AttachmentPhotoSource) -> Void, dismiss: DismissAction) {
            self.onSelect = onSelect; self.dismiss = dismiss
        }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            defer { dismiss() }
            if let result = results.first { onSelect(AttachmentPhotoSource(provider: result.itemProvider)) }
        }
    }
}
#endif

struct RoomChatPanel: View {
    @Environment(\.roomNeedsVerification) private var needsVerification
    @ObservedObject var call: CallController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                MessageLabel("房间聊天", systemImage: "bubble.left.and.bubble.right")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(ChirpTheme.ink)
                Spacer(minLength: 8)
                Image(systemName: needsVerification ? "exclamationmark.shield" : call.chat.isReady ? "lock.shield" : "lock.rotation")
                    .foregroundStyle(needsVerification ? ChirpTheme.roomVerificationInk : ChirpTheme.accent)
                    .messageAccessibilityLabel(needsVerification ? "等待设备互认" : call.chat.isReady ? "端到端加密已就绪" : "安全连接更新中")
            }
            .padding(20)
            Divider().overlay(ChirpTheme.border)
            RoomChatTranscript(messages: call.chat.messages, localIdentity: call.chat.admission?.identity, attachments: call.attachments,
                draftIsEmpty: call.chat.draft.isEmpty, restore: { id in
                    if let entryID = call.chat.admission?.entryID { call.restoreFailedChat(id, entryID: entryID) }
                })
                .equatable()
            Divider().overlay(ChirpTheme.border)
            RoomChatComposer(call: call).padding(16)
        }
        #if os(macOS)
        .background(needsVerification ? ChirpTheme.roomVerificationCanvas : ChirpTheme.chatCanvas)
        #else
        .background(needsVerification ? ChirpTheme.roomVerificationCanvas : ChirpTheme.canvas)
        #endif
    }
}

/// Audio activity and composer edits do not invalidate the message list.
struct RoomChatTranscript: View, Equatable {
    let messages: [ChatMessage]
    let localIdentity: String?
    var attachments: RoomAttachmentController? = nil
    var draftIsEmpty = true
    var restore: ((UUID) -> Void)? = nil
    @State private var isNearBottom = true
    @State private var scrollPosition = ScrollPosition(idType: String.self, edge: .bottom)

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messages == rhs.messages && lhs.localIdentity == rhs.localIdentity && lhs.draftIsEmpty == rhs.draftIsEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                if messages.isEmpty { RoomChatEmptyState() }
                ForEach(messages) { message in
                    RoomChatMessageRow(message: message, isOwn: message.sender == localIdentity, attachments: attachments,
                        canRestore: draftIsEmpty, restore: restore.map { restore in { restore(message.messageID) } })
                        .equatable()
                        .id(message.id)
                }
            }
            .padding(18)
            .scrollTargetLayout()
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY < 100
        } action: { _, value in isNearBottom = value }
        .onChange(of: messages.last?.id) { _, id in
            guard id != nil, let last = messages.last,
                  isNearBottom || last.sender == localIdentity else { return }
            scrollPosition.scrollTo(edge: .bottom)
        }
        .accessibilityIdentifier("room-chat-transcript")
    }
}

struct RoomChatEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light)).foregroundStyle(ChirpTheme.accent)
                .accessibilityHidden(true)
            MessageText("也可以，打字聊聊").font(.subheadline.weight(.medium)).foregroundStyle(ChirpTheme.ink)
            MessageText("只显示本次加入后收到的消息。")
                .font(.caption).foregroundStyle(ChirpTheme.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityIdentifier("room-chat-empty")
    }
}

#Preview("文字消息") {
    RoomChatMessageRow(message: ChatMessage(messageID: UUID(), sender: "sample", senderName: "朋友",
        text: "今晚一起聊聊？\n这条消息只在本次入房期间保留。", time: Date(timeIntervalSince1970: 0),
        delivery: .received), isOwn: false)
        .padding().frame(width: 320)
}

#Preview("尚未就绪") {
    RoomChatComposer(call: CallController()).padding().frame(width: 320)
}
