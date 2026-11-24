import SwiftUI

struct AudioPresetSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var call: CallController
    @State private var selection: AudioPreset
    @State private var errorMessage: ClientFailure?
    @State private var microphoneTestOwner = UUID()

    init(call: CallController) {
        self.call = call
        _selection = State(initialValue: call.audioPreset)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 5) {
                            MessageText("让声音更清楚").font(.headline)
                            MessageText("选择适合当前设备的音频处理方式。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "headphones").font(.title2).foregroundStyle(ChirpTheme.accent)
                            .frame(width: 48, height: 48)
                            .background(ChirpTheme.surfaceSubtle, in: .rect(cornerRadius: 16))
                    }
                    .padding(.vertical, 8)
                }
                Section("音频预设") {
                    Picker("处理方式", selection: $selection) {
                        ForEach(AudioPreset.allCases) { preset in MessageText(preset.title).tag(preset) }
                    }
                    #if os(macOS)
                    .pickerStyle(.radioGroup)
                    #else
                    .pickerStyle(.inline)
                    #endif
                    .accessibilityIdentifier("audio-preset-picker")
                    MessageText(selection.explanation).font(.callout).foregroundStyle(.secondary)
                }
                CallAudioSettingsSections(call: call, testOwner: microphoneTestOwner)
                Section {
                    MessageLabel(call.audioPreset.usesRNNoise ? "RNNoise 已启用" : "RNNoise 未启用", systemImage: "waveform")
                    MessageText("所有预设都在本机处理音频后再加密发送。")
                        .font(.caption).foregroundStyle(.secondary)
                    MessageText("切换无需重启应用。通话中切换时可能短暂调整音频，麦克风静音状态保持不变。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("当前状态") {
                    MessageText(call.audioProcessingStatus).font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("audio-preset-status")
                    if let errorMessage {
                        FailureText(errorMessage).foregroundStyle(ChirpTheme.danger).font(.callout).textSelection(.enabled)
                    }
                    if call.isChangingAudioPreset { ProgressView("正在切换音频预设") }
                }
            }
            .formStyle(.grouped)
            .chirpForm()
            .messageNavigationTitle("声音设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.disabled(call.isChangingAudioPreset)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        errorMessage = nil
                        Task {
                            do { try await call.changeAudioPreset(to: selection) }
                            catch is CancellationError { return }
                            catch { errorMessage = ClientFailure.capture(error, fallback: .audioPresetUnconfirmed) }
                        }
                    }
                    .disabled(selection == call.audioPreset || !call.canChangeAudioPreset)
                    .accessibilityIdentifier("apply-audio-preset")
                }
            }
            .interactiveDismissDisabled(call.isChangingAudioPreset)
        }
        .logScreen("audioSettings")
        .task {
            var releaseSession: (() -> Void)?
            do { releaseSession = try call.audio.acquireSettingsSession() }
            catch { errorMessage = ClientFailure.capture(error, fallback: .audioDeviceChangeFailed) }
            defer { releaseSession?() }
            await call.audio.refresh()
            while !Task.isCancelled {
                call.voiceActivation.refresh()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        .onDisappear { call.audio.cancelTest(owner: microphoneTestOwner) }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 560)
        #endif
    }
}
