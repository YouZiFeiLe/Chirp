import SwiftUI

struct VoiceActivationSettingsSection: View {
    @ObservedObject private var call: CallController
    @ObservedObject private var audio: CallAudioController
    @ObservedObject private var activation: VoiceActivationController

    init(call: CallController) {
        self.call = call; audio = call.audio; activation = call.voiceActivation
    }

    private var hasInput: Bool {
        activation.reading.isProcessing &&
            (audio.testPhase == .measuring || (call.isConnected && !call.isMuted))
    }

    private var status: LocalizedMessage {
        if call.hasSession && call.isMuted { return "麦克风已静音" }
        if !hasInput { return "开启麦克风或开始本机测试以查看电平" }
        if !activation.settings.enabled { return "语音激活已关闭" }
        return activation.reading.isOpen ? "已激活" : "等待声音超过阈值"
    }

    var body: some View {
        Section("语音激活") {
            Toggle(isOn: Binding(get: { activation.settings.enabled }, set: activation.setEnabled)) {
                MessageText("启用语音激活")
            }
            .accessibilityIdentifier("voice-activation-enabled")
            LabeledContent {
                Text("\(Int(activation.settings.thresholdDBFS)) dBFS").monospacedDigit()
            } label: { MessageText("激活阈值") }
            Slider(value: Binding(get: { activation.settings.thresholdDBFS }, set: activation.setThreshold),
                   in: VoiceActivationSettings.thresholdRange, step: 1) {
                MessageText("激活阈值")
            } onEditingChanged: { editing in
                if !editing { ClientLog.shared.record(.audio, "changeActivationThreshold") }
            }
            .disabled(!activation.settings.enabled)
            .accessibilityIdentifier("voice-activation-threshold")
            HStack {
                MessageText("更灵敏")
                Spacer()
                MessageText("更安静")
            }
            .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    MessageText("输入电平")
                    Spacer()
                    if hasInput {
                        Text("\(Int(activation.reading.inputDBFS.rounded())) dBFS").monospacedDigit()
                    } else { Text("—") }
                }
                .font(.caption).foregroundStyle(.secondary)
                AudioInputLevelMeter(level: hasInput ? activation.reading.level : 0,
                    isOpen: activation.settings.enabled && activation.reading.isOpen,
                    thresholdDBFS: activation.settings.enabled ? activation.settings.thresholdDBFS : nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("输入电平")
                .accessibilityValue(hasInput ? "\(Int(activation.reading.inputDBFS.rounded())) dBFS" : "—")
                .accessibilityIdentifier("voice-activation-level")
                MessageText(status).font(.caption)
                    .accessibilityIdentifier("voice-activation-status")
            }
            MessageText("适用于所有音频预设，调整后立即生效并保存在本机。提高阈值可减少底噪触发；轻声说话被截断时，请降低阈值。")
                .font(.caption).foregroundStyle(.secondary)
            MessageText("等待激活时麦克风仍在采集。手动静音始终优先；说话时的背景噪音仍由音频预设处理。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Both settings meters use the same sampled reading, scale and animation.
struct AudioInputLevelMeter: View {
    let level: Double
    var isOpen = false
    var thresholdDBFS: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.15))
                Capsule().fill(isOpen ? Color.green : ChirpTheme.accent)
                    .frame(width: geometry.size.width * level)
                if let thresholdDBFS {
                    Rectangle().fill(.primary).frame(width: 2)
                        .offset(x: max(0, (geometry.size.width - 2) * (thresholdDBFS + 80) / 80))
                }
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.1), value: level)
    }
}
