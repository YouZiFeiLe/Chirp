import ChirpMLS
import SwiftUI

struct SettingsIcon: View {
    let systemImage: String
    var color = ChirpTheme.accent

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 38, height: 38)
            .background(color.opacity(0.09), in: .rect(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

struct SettingsRow: View {
    let title: LocalizedMessage
    let subtitle: LocalizedMessage
    let systemImage: String
    var color = ChirpTheme.accent

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(systemImage: systemImage, color: color)
            VStack(alignment: .leading, spacing: 4) {
                MessageText(title).font(.body.weight(.medium)).foregroundStyle(ChirpTheme.ink)
                MessageText(subtitle).font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold)).foregroundStyle(ChirpTheme.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .frame(minHeight: 48)
        .contentShape(.rect)
    }
}

struct SettingsPageHeading: View {
    let title: LocalizedMessage
    let subtitle: LocalizedMessage
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SettingsIcon(systemImage: systemImage)
            VStack(alignment: .leading, spacing: 8) {
                MessageText(title)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(ChirpTheme.ink).accessibilityAddTraits(.isHeader)
                MessageText(subtitle).font(.callout).foregroundStyle(ChirpTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

struct SettingsEmptyState: View {
    let title: LocalizedMessage
    let subtitle: LocalizedMessage
    let systemImage: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light)).foregroundStyle(ChirpTheme.accent)
                .frame(width: 72, height: 72).background(ChirpTheme.surfaceSubtle, in: .circle)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                MessageText(title).font(.headline).foregroundStyle(ChirpTheme.ink)
                MessageText(subtitle).font(.callout).foregroundStyle(ChirpTheme.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 24)
        .chirpSurface(padding: 0)
        .accessibilityElement(children: .combine)
    }
}

struct IdentityFingerprint: View {
    let key: String
    var title: LocalizedMessage = "设备指纹"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MessageText(title).font(.caption.weight(.medium)).foregroundStyle(ChirpTheme.secondary)
            if let fingerprint = try? V5Crypto.fingerprint(key) {
                Text(verbatim: fingerprint)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(ChirpTheme.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else {
                MessageText("暂无指纹记录").font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(ChirpTheme.surfaceSubtle.opacity(0.65), in: .rect(cornerRadius: 12))
    }
}

struct SettingsStatus: View {
    let title: LocalizedMessage
    let systemImage: String
    var color = ChirpTheme.accent

    var body: some View {
        MessageLabel(title, systemImage: systemImage)
            .font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.08), in: .capsule)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsFailure: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
            Text(verbatim: message).textSelection(.enabled)
        }
        .font(.callout).foregroundStyle(ChirpTheme.danger)
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(ChirpTheme.danger.opacity(0.06), in: .rect(cornerRadius: 14))
    }
}
