import SwiftUI
#if os(iOS)
import AVKit
#endif

struct CallAudioSettingsSections: View {
    @ObservedObject var call: CallController
    @ObservedObject private var audio: CallAudioController
    @ObservedObject private var activation: VoiceActivationController
    @State private var error: ClientFailure?
    let testOwner: UUID
    init(call: CallController, testOwner: UUID) {
        self.call = call; audio = call.audio; activation = call.voiceActivation
        self.testOwner = testOwner
    }
    private var devicesDisabled: Bool {
        call.isBusy || call.isChangingAudioPreset || call.isChangingMicrophone || audio.isChangingDevice || audio.testPhase != .idle
    }
    private var microphoneLevel: Double {
        audio.testPhase == .measuring && activation.reading.isProcessing ? activation.reading.level : 0
    }

    var body: some View {
        Section("音频设备与路由") {
            Picker("输入设备", selection: Binding(get: { audio.devices.inputID }, set: { id in
                perform { try await audio.selectInput(id) }
            })) {
                MessageText("系统默认").tag("system")
                ForEach(audio.devices.inputs) { Text($0.name).tag($0.id) }
            }
            .disabled(devicesDisabled || !audio.isAvailable)
            .accessibilityIdentifier("audio-input-device")
            #if os(macOS)
            Picker("输出设备", selection: Binding(get: { audio.devices.outputID }, set: { id in
                perform { try await audio.selectOutput(id) }
            })) {
                MessageText("系统默认").tag("system")
                ForEach(audio.devices.outputs) { Text($0.name).tag($0.id) }
            }
            .disabled(devicesDisabled || !audio.isAvailable)
            .accessibilityIdentifier("audio-output-device")
            #else
            Picker("输出设备", selection: Binding(get: { audio.output }, set: { output in
                perform { try await audio.preferOutput(output) }
            })) {
                MessageText("系统路由").tag(CallAudioOutput.system)
                MessageText("扬声器").tag(CallAudioOutput.speaker)
                if audio.devices.supportsReceiver {
                    MessageText("听筒").tag(CallAudioOutput.receiver)
                }
            }
            .disabled(devicesDisabled || !audio.isAvailable)
            .accessibilityIdentifier("audio-output-device")
            HStack {
                MessageText("耳机与蓝牙路由")
                Spacer()
                CallAudioRoutePicker().frame(width: 44, height: 44)
            }
            #endif
            if !audio.devices.inputName.isEmpty {
                LabeledContent { Text(audio.devices.inputName).multilineTextAlignment(.trailing) } label: { MessageText("当前输入") }
            }
            if !audio.devices.outputName.isEmpty {
                LabeledContent {
                    MessageText(audio.devices.outputTitle).multilineTextAlignment(.trailing)
                } label: { MessageText("当前输出") }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("当前输出")
                .messageAccessibilityValue(audio.devices.outputTitle)
                .accessibilityIdentifier("audio-current-output")
            }
            if audio.devices.fellBackToDefault {
                MessageLabel("原设备已断开，已回退到系统默认设备", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if audio.isChangingDevice { ProgressView("正在切换音频设备") }
            if let error = error ?? audio.error { FailureText(error).foregroundStyle(ChirpTheme.danger).font(.callout) }
        }
        VoiceActivationSettingsSection(call: call)
        Section("麦克风测试") {
            MessageText("仅在本机测试，最长采集十秒。试听最近三秒，不上传、不保存文件。")
                .font(.caption).foregroundStyle(.secondary)
            AudioInputLevelMeter(level: microphoneLevel)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("输入音量")
                .accessibilityValue(microphoneLevel.formatted(.percent.precision(.fractionLength(0))))
                .accessibilityIdentifier("microphone-test-level")
            if audio.testPhase == .idle {
                Button("开始麦克风测试") { perform { try await call.startMicrophoneTest(owner: testOwner) } }
                    .disabled(!call.canStartMicrophoneTest || audio.isChangingDevice)
                    .accessibilityIdentifier("start-microphone-test")
            } else {
                HStack {
                    Button("停止测试") { audio.cancelTest() }
                        .accessibilityIdentifier("stop-microphone-test")
                    Spacer()
                    Button("停止并试听") { audio.cancelTest(playSample: true) }
                        .disabled(audio.testPhase != .measuring)
                        .accessibilityIdentifier("play-microphone-test")
                }
                // Form's automatic style makes both actions belong to the row
                // on iOS. Each button must handle only its own tap.
                #if os(iOS)
                .buttonStyle(.borderless)
                #endif
                if audio.testPhase == .starting || audio.testPhase == .stopping { ProgressView("正在调整测试音频") }
                if audio.testPhase == .playing { MessageText("正在试听本机录音").font(.caption) }
            }
            if call.hasSession { MessageText("离开语音后可测试麦克风").font(.caption).foregroundStyle(.secondary) }
        }
        if call.hasSession {
            Section("通话声音") {
                #if os(macOS)
                Toggle(isOn: Binding(get: { call.isListening }, set: { if $0 != call.isListening { call.toggleListening() } })) {
                    MessageText("收听房间音频")
                }
                .accessibilityIdentifier("listen-to-call")
                MessageText("收听开关只影响本机播放，麦克风静音状态保持不变。")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                MessageText(call.status).font(.callout)
                if call.canResumeAudio {
                    Button("恢复音频", action: call.resumeAudio).accessibilityIdentifier("resume-call-audio")
                }
            }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task { @MainActor in
            do { try await action() }
            catch is CancellationError { return }
            catch { self.error = ClientFailure.capture(error, fallback: .audioDeviceChangeFailed) }
        }
    }
}

extension CallNetworkQuality {
    var title: LocalizedMessage {
        switch self {
        case .unknown: "网络状态待确认"
        case .excellent: "网络良好"
        case .good: "网络正常"
        case .poor: "网络较差"
        case .lost: "网络连接丢失"
        }
    }
}

#if os(iOS)
struct CallAudioRoutePicker: UIViewRepresentable {
    @Environment(\.locale) private var locale
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.activeTintColor = .systemTeal
        return picker
    }
    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        let message: LocalizedMessage = "切换音频路由"
        picker.accessibilityLabel = message.localized(in: locale)
    }
}
#endif
