import SwiftUI
import UniformTypeIdentifiers

private extension AttachmentTransferState {
    var title: LocalizedMessage {
        switch phase {
        case .waiting: remoteState == .completed ? "附件可下载" : remoteState == .paused ? "发送方上传已暂停" : "等待发送方上传"
        case .reserving: "正在准备上传"
        case .uploading: "正在上传"
        case .waitingForUpload: "等待发送方完成上传"
        case .downloading: "正在下载"
        case .verifying: "正在校验附件"
        case .completed:
            if remoteState == .delivered { "服务器副本已删除，本地仍可用" }
            else if remoteState == .expired { "服务器副本已过期，本地仍可用" }
            else { "附件已就绪" }
        case .retryableFailure: "传输中断，可以继续"
        case .failed: "附件校验或权限检查失败"
        case .cancelling: "正在确认取消结果"
        case .cancelled: "发送方已取消附件"
        case .expired: "附件已过期"
        case .downloadPaused: "下载已暂停"
        }
    }
}

struct AttachmentComposerStatus: View {
    @ObservedObject var attachments: RoomAttachmentController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if attachments.isSending {
                HStack {
                    ProgressView().controlSize(.mini); MessageText("正在准备或上传附件")
                    Button { attachments.cancelPreparation() } label: { MessageText("取消").roomActionTarget() }.buttonStyle(.bordered)
                }
            }
            ForEach(attachments.unpublished) { info in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: info.name).lineLimit(1)
                    AttachmentTransferActions(info: info, attachments: attachments)
                }
            }
            if attachments.states.values.contains(where: \.busy) {
                if attachments.networkPolicy == .paused { MessageText("语音优先：附件传输已暂停") }
                else if attachments.networkPolicy == .constrained { MessageText("语音优先：附件正在低速传输") }
            }
            if let error = attachments.error { FailureText(error).foregroundStyle(ChirpTheme.warning) }
        }
        .font(.caption).foregroundStyle(ChirpTheme.secondary)
    }
}

private struct AttachmentTransferActions: View {
    let info: AttachmentInfo
    @ObservedObject var attachments: RoomAttachmentController
    private var state: AttachmentTransferState? { attachments.states[info.id] }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { buttons }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
        .buttonStyle(.bordered)
    }
    @ViewBuilder private var buttons: some View {
            if attachments.canRetry(info) {
                Button { attachments.retry(info) } label: {
                    MessageLabel(state?.outgoing == true ? "重试上传" : "继续下载", systemImage: "arrow.clockwise").roomActionTarget()
                }
            }
            if attachments.canCancel(info) {
                Button { attachments.cancelUpload(info) } label: {
                    MessageLabel(state?.phase == .cancelling ? "重试取消" : "取消上传", systemImage: "xmark").roomActionTarget()
                }
            }
            if state?.outgoing != true, state?.busy == true {
                Button { attachments.pauseDownload(info) } label: { MessageLabel("暂停下载", systemImage: "pause").roomActionTarget() }
            }
    }
}

struct RoomAttachmentRow: View {
    let info: AttachmentInfo
    @ObservedObject var attachments: RoomAttachmentController
    @State private var thumbnail: AttachmentImage?
    @State private var showsExportFolder = false
    private var state: AttachmentTransferState? { attachments.states[info.id] }
    private var number: Int { Int((state?.progress ?? 0) * 100) }
    private var canOpen: Bool {
        attachments.available(info) && state?.busy != true && state?.phase != .cancelling
            && state?.phase != .failed && state?.phase != .retryableFailure && state?.phase != .downloadPaused
            && (state?.cached == true || state?.remoteState == .completed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let thumbnail, attachments.available(info) {
                Button { Task { await attachments.showPreview(info) } } label: {
                    Image(decorative: thumbnail.image, scale: 1)
                        .resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 180)
                        .clipShape(.rect(cornerRadius: 10))
                }
                .buttonStyle(.plain).disabled(!canOpen)
                .messageAccessibilityLabel("查看图片")
            }
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: info.name).lineLimit(2).font(.subheadline.weight(.medium))
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: info.size, countStyle: .file))
                        .font(.caption).foregroundStyle(ChirpTheme.secondary)
                }
            } icon: { Image(systemName: info.isImage ? "photo" : "doc") }
            if let state {
                MessageText(state.title).font(.caption).foregroundStyle(state.failed ? ChirpTheme.warning : ChirpTheme.secondary)
                if state.busy, state.phase != .cancelling {
                    ProgressView(value: state.progress)
                    MessageText("传输中 · \(number)%").font(.caption2).foregroundStyle(ChirpTheme.secondary)
                }
            }
            if !attachments.available(info), state?.phase != .cancelled, state?.phase != .expired {
                MessageText("附件缓存已清理").font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
            AttachmentTransferActions(info: info, attachments: attachments)
            if canOpen {
                HStack(spacing: 12) {
                    if info.isImage {
                        Button { Task { await attachments.showPreview(info) } } label: { MessageLabel("查看图片", systemImage: "arrow.up.left.and.arrow.down.right").roomActionTarget() }
                    }
                    Button {
                        Task { if await attachments.prepareExport(info) { showsExportFolder = true } }
                    } label: { MessageLabel("保存到文件夹", systemImage: "square.and.arrow.down").roomActionTarget() }
                }
                .font(.caption).buttonStyle(.bordered)
            } else if attachments.available(info), state?.phase == .waiting, state?.outgoing != true {
                Button { Task { _ = await attachments.prepareExport(info) } } label: { MessageLabel("下载附件", systemImage: "arrow.down").roomActionTarget() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(minWidth: 180, maxWidth: 280, alignment: .leading)
        .background(ChirpTheme.surfaceSubtle, in: .rect(cornerRadius: 14))
        .task(id: attachments.revision) {
            thumbnail = nil
            let token = attachments.revision
            let image = await attachments.thumbnail(info)
            if !Task.isCancelled, attachments.revision == token, attachments.available(info) { thumbnail = image }
        }
        .onDisappear { thumbnail = nil }
        .fileImporter(isPresented: $showsExportFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(directory) = result { Task { await attachments.export(info, to: directory) } }
        }
        .privacySensitive()
        .accessibilityIdentifier("room-chat-attachment")
    }
}

struct AttachmentPreviewPresenter: View {
    @ObservedObject var attachments: RoomAttachmentController
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(item: $attachments.preview) { preview in
                AttachmentPreviewView(preview: preview)
            }
    }
}

private struct AttachmentPreviewView: View {
    let preview: AttachmentPreview
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Image(decorative: preview.image.image, scale: 1).resizable().scaledToFit().padding()
                .navigationTitle(Text(verbatim: preview.info.name))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .frame(minWidth: 300, minHeight: 300)
        .privacySensitive()
    }
}

#Preview("附件已清理") {
    RoomAttachmentRow(info: AttachmentInfo(version: 1, id: String(repeating: "a", count: 32), roomID: "friends",
        sender: "sample.login.entry", name: "weekend-plan.pdf", mimeType: "application/pdf", size: 2_048_000,
        digest: String(repeating: "0", count: 64), hasThumbnail: false),
        attachments: RoomAttachmentController(cache: AttachmentCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))))
        .padding()
}

#if DEBUG
struct AttachmentTransferReference: View {
    @StateObject private var attachments: RoomAttachmentController
    private let infos: [AttachmentInfo]
    @State private var draft = ""
    init() {
        let fixture = RoomAttachmentController.transferReference()
        _attachments = StateObject(wrappedValue: fixture.0); infos = fixture.1
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MessageText("离线设计预览 · 示例数据").font(.headline)
                RoomChatMessageRow(message: ChatMessage(messageID: UUID(), sender: "sample.login.entry", senderName: "Sample",
                    text: "See you this weekend.", time: Date(), delivery: .failed), isOwn: true, canRestore: draft.isEmpty,
                    restore: { draft = "See you this weekend." })
                TextField("", text: $draft).textFieldStyle(.roundedBorder)
                    .messageAccessibilityLabel("消息草稿")
                ForEach(infos) { RoomAttachmentRow(info: $0, attachments: attachments) }
            }
            .padding(20).frame(maxWidth: 520, alignment: .leading)
        }
        .frame(minWidth: 300, minHeight: 500)
        .background(ChirpTheme.canvas)
    }
}
#Preview("附件状态") { AttachmentTransferReference() }
#endif
