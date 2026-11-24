import SwiftUI

struct NetworkClockNotice: View {
    let clock: NetworkClock
    @Environment(\.locale) private var locale

    var body: some View {
        if clock.status != .ready {
            VStack(alignment: .leading, spacing: 8) {
                MessageLabel(message, systemImage: "clock")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("network-clock-notice")
                if case .outOfSync = clock.status {
                    #if os(macOS)
                    Link(destination: URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension")!) {
                        MessageText("打开日期与时间设置")
                    }
                    #else
                    MessageText("请在「设置 → 通用 → 日期与时间」中开启「自动设置」。")
                    #endif
                }
                if clock.status != .checking {
                    Button { Task { await clock.check(manual: true) } } label: { MessageText("重新校验") }
                        .buttonStyle(.borderless).disabled(!clock.canRetry)
                        .accessibilityIdentifier("retry-network-clock")
                }
            }
            .font(.callout).foregroundStyle(ChirpTheme.ink)
        }
    }

    private var message: LocalizedMessage {
        switch clock.status {
        case .ready, .checking:
            return "正在校验系统时间，校验通过后即可登录或授权设备。"
        case .unavailable:
            return "暂时无法核实网络时间。请检查网络是否允许 NTP（UDP 123），客户端会自动重试。"
        case .outOfSync(let offset):
            let seconds = abs(offset).formatted(.number.precision(.fractionLength(1)).locale(locale))
            return offset > 0 ? "本机时间比网络时间快约 \(seconds) 秒。请同步系统时间，校准后即可登录或授权设备。"
                : "本机时间比网络时间慢约 \(seconds) 秒。请同步系统时间，校准后即可登录或授权设备。"
        }
    }
}
