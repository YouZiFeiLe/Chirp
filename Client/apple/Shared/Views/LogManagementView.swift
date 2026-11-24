import SwiftUI
import UniformTypeIdentifiers

private struct ChirpLogExport: Transferable {
    static let contentType = UTType(exportedAs: "cn.youzifeile.chirp.log", conformingTo: .data)
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: contentType) { $0.data }
    }
}

struct LogManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ClientLog.preference) private var enabled = false
    @State private var busy = false
    @State private var confirmingClear = false
    @State private var exporting = false
    @State private var document: ChirpLogExport?
    @State private var status: LocalizedMessage?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { enabled }, set: { value in
                        status = nil
                        ClientLog.shared.setEnabled(value)
                    })) {
                        MessageText("记录客户端日志")
                    }
                    .accessibilityIdentifier("log-recording")
                } footer: {
                    MessageText("在本机记录所有账号的操作和通话性能，保留最近 24 小时。账号标识、消息、音频和密钥不会写入日志。")
                }
                Section {
                    Button(action: prepareExport) { MessageLabel("导出日志", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("export-client-log")
                    Button(role: .destructive) { confirmingClear = true } label: { MessageLabel("清除日志", systemImage: "trash") }
                        .accessibilityIdentifier("clear-client-log")
                    if busy { ProgressView() }
                    if let status { MessageText(status).foregroundStyle(.secondary).accessibilityIdentifier("log-status") }
                } footer: {
                    MessageText("导出的 .chirplog 文件可手动发送给支持人员。")
                }
            }
            .formStyle(.grouped)
            .chirpForm()
            .disabled(busy)
            .messageNavigationTitle("日志管理")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .logScreen("logSettings")
        .confirmationDialog("清除本机记录的全部日志？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清除日志", role: .destructive, action: clear)
            Button("取消", role: .cancel) {}
        }
        .fileExporter(isPresented: $exporting, item: document, contentTypes: [ChirpLogExport.contentType],
                      defaultFilename: "Chirp-\(Date.now.formatted(.iso8601.year().month().day()))") { result in
            document = nil
            switch result {
            case .success:
                ClientLog.shared.record(.settings, "exportLogs", outcome: .succeeded)
                status = "日志已导出"
            case .failure:
                ClientLog.shared.record(.settings, "exportLogs", outcome: .failed)
                status = "日志导出失败，请重试。"
            }
        } onCancellation: {
            document = nil
            ClientLog.shared.record(.settings, "exportLogs", outcome: .cancelled)
        }
        #if os(macOS)
        .frame(width: 480, height: 360)
        #endif
        .withAppLanguage()
    }

    private func prepareExport() {
        busy = true; status = nil
        Task {
            defer { busy = false }
            do {
                document = ChirpLogExport(data: try await ClientLog.shared.export())
                exporting = true
            } catch ChirpLogError.empty { status = "暂无可导出的日志" }
            catch { status = "日志导出失败，请重试。" }
        }
    }

    private func clear() {
        busy = true; status = nil
        Task {
            defer { busy = false }
            do { try await ClientLog.shared.clear(); document = nil; status = "本机日志已清除" }
            catch { status = "日志清除失败，请重试。" }
        }
    }
}
