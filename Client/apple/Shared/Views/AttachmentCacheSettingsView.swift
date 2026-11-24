import SwiftUI

struct AttachmentCacheSettingsView: View {
    private let cache: AttachmentCache
    init(cache: AttachmentCache = .shared) { self.cache = cache }
    @Environment(\.dismiss) private var dismiss
    @State private var bytes: Int64 = 0
    @State private var busy = false
    @State private var didClear = false
    @State private var error: ClientFailure?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent { Text(verbatim: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                        label: { MessageText("附件缓存占用") }
                    Button(action: clear) {
                        HStack {
                            MessageLabel("清空全部附件缓存", systemImage: "trash")
                            if busy { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("clear-attachment-cache")
                    if didClear { MessageLabel("附件缓存已清空", systemImage: "checkmark.circle").foregroundStyle(ChirpTheme.accent) }
                    if let error { FailureText(error).foregroundStyle(ChirpTheme.warning) }
                } footer: {
                    MessageText("清理此设备上全部房间的附件缓存并取消传输。当前聊天中的附件将失效，语音和文字消息保留。你保存到其他文件夹的文件不会被删除。")
                }
                Section {
                    MessageText("离房时自动清理附件缓存；如果应用意外退出，下次启动时也会自动清理。")
                        .foregroundStyle(ChirpTheme.secondary)
                }
            }
            .logScreen("attachmentCache")
            .formStyle(.grouped)
            .messageNavigationTitle("存储与缓存")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { bytes = await Task.detached(priority: .utility) { [cache] in cache.size() }.value }
        }
        #if os(macOS)
        .frame(width: 480, height: 380)
        #endif
    }

    private func clear() {
        guard !busy else { return }; busy = true; didClear = false; error = nil
        Task {
            do {
                try await Task.detached(priority: .utility) { [cache] in try cache.clearAll() }.value
                NotificationCenter.default.post(name: AttachmentCache.didClear, object: nil)
                ClientLog.shared.record(.settings, "clearAttachmentCache", outcome: .succeeded)
                bytes = cache.size(); didClear = true
            } catch {
                // Leases are revoked even when deleting a file fails.
                NotificationCenter.default.post(name: AttachmentCache.didClear, object: nil)
                ClientLog.shared.record(.settings, "clearAttachmentCache", outcome: .failed, failure: ClientFailure(.attachmentCacheFailed))
                self.error = ClientFailure(.attachmentCacheFailed)
            }
            busy = false
        }
    }
}

#Preview("存储与缓存") {
    AttachmentCacheSettingsView(cache: AttachmentCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
}
