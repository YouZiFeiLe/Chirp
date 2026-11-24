import SwiftUI

struct SASVerificationProgress: View {
    let step: SASVerificationStep
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let titles: [LocalizedMessage] = ["准备核验", "比较安全码", "双方确认"]
    private var progressLabel: LocalizedMessage {
        let number = step.progress
        return "设备互认进度，第 \(number) 步，共 3 步"
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) { steps }
            } else {
                HStack(alignment: .top, spacing: 8) { steps }
            }
        }
        .accessibilityElement(children: .ignore)
        .messageAccessibilityLabel(progressLabel)
        .accessibilityIdentifier("sas-progress")
    }

    private var steps: some View {
        ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
            let complete = step == .completed || index + 1 < step.progress
            let active = index + 1 == step.progress
            HStack(spacing: 8) {
                Group {
                    if complete { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                    else { Text(verbatim: String(index + 1)).font(.caption.weight(.semibold)) }
                }
                .foregroundStyle(complete || active ? ChirpTheme.onAccent : ChirpTheme.secondary)
                .frame(width: 26, height: 26)
                .background(complete || active ? ChirpTheme.accent : ChirpTheme.surfaceSubtle, in: .circle)
                MessageText(title).font(.caption.weight(active ? .semibold : .regular))
                    .foregroundStyle(complete || active ? ChirpTheme.ink : ChirpTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SASVerificationGuidance: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            guidance("先联系上本人", detail: "请当面或通过另一条已认证的渠道联系朋友。本房间不能用来核对安全码。", symbol: "person.wave.2")
            guidance("一起核对安全码", detail: "对方接受邀请后，两边都会出现三组数字，请逐组比较。", symbol: "number.square")
            guidance("双方分别确认", detail: "三组数字全部一致时，两边都点击确认，才会建立设备信任。", symbol: "checkmark.shield")
        }
    }

    private func guidance(_ title: LocalizedMessage, detail: LocalizedMessage, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.body.weight(.medium)).foregroundStyle(ChirpTheme.accent)
                .frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                MessageText(title).font(.subheadline.weight(.semibold)).foregroundStyle(ChirpTheme.ink)
                MessageText(detail).font(.subheadline).foregroundStyle(ChirpTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct SASDecimalGroups: View {
    let decimals: [Int]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var digitSize: CGFloat = 30

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) { groups }
            } else {
                HStack(spacing: 10) { groups }
            }
        }
        .padding(16).background(ChirpTheme.hero, in: .rect(cornerRadius: 20))
        .accessibilityIdentifier("sas-decimal-groups")
    }

    private var groups: some View {
        ForEach(Array(decimals.enumerated()), id: \.offset) { index, value in
            VStack(spacing: 8) {
                MessageText("第 \(index + 1) 组").font(.caption).foregroundStyle(ChirpTheme.secondary)
                Text(verbatim: String(value)).font(.system(size: digitSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ChirpTheme.accent).textSelection(.enabled)
                    .minimumScaleFactor(0.7).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .accessibilityElement(children: .ignore)
            .messageAccessibilityLabel("第 \(index + 1) 组安全码")
            .accessibilityValue(Text(verbatim: String(value).map(String.init).joined(separator: " ")))
        }
    }
}

struct SASVerificationNotice: View {
    let title: LocalizedMessage
    let detail: LocalizedMessage
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).font(.body).foregroundStyle(ChirpTheme.accent)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                MessageText(title).font(.subheadline.weight(.medium)).foregroundStyle(ChirpTheme.ink)
                MessageText(detail).font(.subheadline).foregroundStyle(ChirpTheme.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct SASVerificationActionBar: View {
    let step: SASVerificationStep
    let trustsDevice: Bool
    let isAddingFriend: Bool
    let canRetry: Bool
    let hasPendingTrustWrite: Bool
    let action: (SASVerificationAction) -> Void

    var body: some View {
        VStack(spacing: 10) {
            switch step {
            case .preparation:
                primary(trustsDevice ? "重新核验当前设备" : "开始设备互认", symbol: "checkmark.shield", action: .start)
                    .disabled(isAddingFriend || !canRetry || hasPendingTrustWrite)
                if hasPendingTrustWrite { footnote("设备信任待同步") }
                else { footnote(trustsDevice ? "你已信任这台设备，可以重新核对安全码。" : "核验完成后会添加为好友，并信任当前设备。") }
            case .invitation:
                primary("接受并显示安全码", symbol: "number.square", action: .accept)
                secondary("暂不核验", action: .close)
            case .comparison:
                primary("三组数字全部一致", symbol: "checkmark", action: .confirm)
                Button(role: .destructive) { action(.mismatch) } label: {
                    MessageLabel("数字不一致，停止核验", systemImage: "xmark.shield").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered).tint(ChirpTheme.danger).accessibilityIdentifier("sas-mismatch")
            case .waitingForPeer, .exchanging, .confirmation, .saving:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    MessageText(step.title).font(.subheadline.weight(.medium))
                }
                .foregroundStyle(ChirpTheme.secondary).frame(maxWidth: .infinity, minHeight: 44)
                footnote(step == .confirmation ? "只有双方都确认，核验才会完成。" : "准备好后会自动继续。")
            case .completed:
                primary("完成，返回房间", symbol: "arrow.turn.up.left", action: .close)
                footnote("返回房间后，按需手动开启麦克风。")
            case .syncPending:
                primary("重试同步", symbol: "arrow.clockwise", action: .sync)
                secondary("稍后再试", action: .close)
            case .ended:
                if canRetry {
                    let busy = step == .ended(.peerBusy)
                    primary(busy ? "重新邀请" : "重新准备核验", symbol: "arrow.clockwise", action: busy ? .start : .retry)
                    secondary("返回房间", action: .close)
                } else { primary("返回房间", symbol: "arrow.turn.up.left", action: .close) }
            }
        }
    }

    private func primary(_ title: LocalizedMessage, symbol: String, action value: SASVerificationAction) -> some View {
        Button { action(value) } label: {
            MessageLabel(title, systemImage: symbol).font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44).modifier(ChirpProminentLabelStyle())
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .accessibilityIdentifier("sas-primary-action")
    }
    private func secondary(_ title: LocalizedMessage, action value: SASVerificationAction) -> some View {
        Button { action(value) } label: { MessageText(title).frame(maxWidth: .infinity, minHeight: 44) }
            .buttonStyle(.borderless).accessibilityIdentifier("sas-secondary-action")
    }
    private func footnote(_ text: LocalizedMessage) -> some View {
        MessageText(text).font(.caption).foregroundStyle(ChirpTheme.secondary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
}
