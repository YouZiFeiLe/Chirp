import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shared semantic tokens. Platform-neutral values and usage live in design-system/chirp-together.
enum ChirpTheme {
    static let canvas = adaptive(0xF4F6F2, 0x101B17)
    static let surface = adaptive(0xFFFFFF, 0x192A23)
    static let surfaceSubtle = adaptive(0xE8F0E7, 0x223A2E)
    static let hero = adaptive(0xE2EEE2, 0x213C2D)
    static let chatCanvas = adaptive(0xEDF3ED, 0x14231D)
    static let chatInput = adaptive(0xE2EBE0, 0x223A2E)
    static let border = adaptive(0xD5DED3, 0x365044)
    static let ink = adaptive(0x1C3028, 0xEDF4EB)
    static let secondary = adaptive(0x5C6D62, 0xAEC2B4)
    static let accent = adaptive(0x246448, 0xA9DAB5)
    static let onAccent = adaptive(0xFFFFFF, 0x123721)
    // Native macOS source lists keep white selected text, including in Dark Mode.
    static let nativeAccent = adaptive(0x246448, 0x477C5C)
    static let danger = adaptive(0xAF403D, 0xFFB4A8)
    static let warning = adaptive(0x805820, 0xE3C08C)
    // These surfaces are scoped to the active Apple room awaiting device verification.
    static let roomVerificationCanvas = adaptive(0xFBEDEA, 0x291F20)
    static let roomVerificationSurface = adaptive(0xFBE1DD, 0x42282B)
    static let roomVerificationInk = adaptive(0x802B28, 0xFFD0C7)

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let section: CGFloat = 40
    }

    enum Radius {
        static let control: CGFloat = 14
        static let card: CGFloat = 24
        static let hero: CGFloat = 32
    }

    static func avatarColors(for identity: String) -> (fill: Color, ink: Color) {
        let pairs: [(Color, Color)] = [
            (adaptive(0xE4EBDE, 0x334530), adaptive(0x47603E, 0xBDD0B2)),
            (adaptive(0xEBE5DD, 0x463C31), adaptive(0x77604A, 0xD6C2AA)),
            (adaptive(0xE5E7ED, 0x363B4B), adaptive(0x56617B, 0xBDC6DE)),
            (adaptive(0xECE3E2, 0x4A3534), adaptive(0x815A55, 0xDCBDB7)),
        ]
        // Media identities add login/entry suffixes; keep the member's color stable across joins.
        let stableIdentity = identity.components(separatedBy: ".login_").first ?? identity
        let index = stableIdentity.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % pairs.count }
        return pairs[index]
    }

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        func components(_ hex: UInt32) -> (Double, Double, Double) {
            (Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255)
        }
        let l = components(light), d = components(dark)
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? d : l
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }
}

struct ChirpWordmark: View {
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            RoomEmblem(size: compact ? 30 : 38)
            Text("Chirp")
                .font(.system(compact ? .title3 : .title, design: .rounded, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(ChirpTheme.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chirp")
    }
}

struct ChirpBadge: View {
    let title: LocalizedMessage
    let systemImage: String
    var emphasized = false

    var body: some View {
        MessageLabel(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(emphasized ? ChirpTheme.accent : ChirpTheme.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(emphasized ? ChirpTheme.accent.opacity(0.10) : ChirpTheme.surface.opacity(0.65), in: .capsule)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ChirpSectionHeading: View {
    let title: LocalizedMessage
    var detail: LocalizedMessage? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            MessageText(title).font(.system(.headline, design: .rounded)).foregroundStyle(ChirpTheme.ink)
            Spacer(minLength: 8)
            if let detail {
                MessageText(detail).font(.caption.monospacedDigit()).foregroundStyle(ChirpTheme.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(ChirpTheme.surfaceSubtle, in: .capsule)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct ChirpSurface: ViewModifier {
    var padding: CGFloat = ChirpTheme.Space.xl
    var cornerRadius: CGFloat = ChirpTheme.Radius.card

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(ChirpTheme.surface, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(ChirpTheme.border.opacity(0.8), lineWidth: 0.75)
            }
    }
}

extension View {
    func chirpSurface(padding: CGFloat = ChirpTheme.Space.xl,
                      cornerRadius: CGFloat = ChirpTheme.Radius.card) -> some View {
        modifier(ChirpSurface(padding: padding, cornerRadius: cornerRadius))
    }

    func chirpForm() -> some View {
        scrollContentBackground(.hidden)
            .background(ChirpTheme.canvas)
            .tint(ChirpTheme.accent)
    }
}

/// Decorative, static sound motif; it does not pretend to show live audio levels.
struct QuietWave: View {
    var size: CGFloat = 156

    var body: some View {
        ZStack {
            Circle().strokeBorder(ChirpTheme.accent.opacity(0.10), lineWidth: 1)
            Circle().strokeBorder(ChirpTheme.accent.opacity(0.16), lineWidth: 1).padding(size * 0.12)
            Circle().fill(ChirpTheme.surface.opacity(0.65)).padding(size * 0.24)
            Circle().fill(ChirpTheme.accent.opacity(0.14))
                .frame(width: size * 0.08, height: size * 0.08)
                .offset(x: size * 0.36, y: -size * 0.34)
            HStack(spacing: size * 0.035) {
                ForEach(Array([0.12, 0.23, 0.34, 0.19, 0.12].enumerated()), id: \.offset) { _, height in
                    Capsule().fill(ChirpTheme.accent)
                        .frame(width: size * 0.035, height: size * height)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ChirpEyebrow: View {
    let title: LocalizedMessage

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(ChirpTheme.accent).frame(width: 18, height: 3).accessibilityHidden(true)
            MessageText(title)
                .font(.caption.weight(.semibold)).tracking(1.2)
                .foregroundStyle(ChirpTheme.accent)
        }
    }
}

/// macOS removes the prominent fill when a window becomes inactive.
/// Keep the label readable against that neutral system surface.
struct ChirpProminentLabelStyle: ViewModifier {
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content.foregroundStyle(appearsActive ? ChirpTheme.onAccent : ChirpTheme.ink)
        #else
        content
        #endif
    }
}
