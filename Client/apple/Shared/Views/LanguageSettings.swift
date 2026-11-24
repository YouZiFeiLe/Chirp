import SwiftUI

/// Resolves only presentation state. Never changes the identity of the app,
/// login session, room watcher, call controller, sheets, or authentication task.
private struct AppLanguageModifier: ViewModifier {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.defaultLanguage
    @Environment(\.scenePhase) private var scenePhase
    @State private var preferredLanguages = Locale.preferredLanguages

    func body(content: Content) -> some View {
        content
            .environment(\.locale, language.resolved(preferredLanguages: preferredLanguages).locale)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { preferredLanguages = Locale.preferredLanguages }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                preferredLanguages = Locale.preferredLanguages
            }
    }
}

extension View {
    func withAppLanguage() -> some View { modifier(AppLanguageModifier()) }
    func messageHelp(_ message: LocalizedMessage) -> some View { modifier(MessageModifier(message: message, kind: .help)) }
    func messageAccessibilityLabel(_ message: LocalizedMessage) -> some View { modifier(MessageModifier(message: message, kind: .label)) }
    func messageAccessibilityValue(_ message: LocalizedMessage) -> some View { modifier(MessageModifier(message: message, kind: .value)) }
    func messageAccessibilityHint(_ message: LocalizedMessage) -> some View { modifier(MessageModifier(message: message, kind: .hint)) }
    func messageNavigationTitle(_ message: LocalizedMessage) -> some View { modifier(MessageModifier(message: message, kind: .title)) }
}

private struct MessageModifier: ViewModifier {
    enum Kind { case help, label, value, hint, title }
    @Environment(\.locale) private var locale
    let message: LocalizedMessage
    let kind: Kind

    @ViewBuilder func body(content: Content) -> some View {
        let text = Text(verbatim: message.localized(in: locale))
        switch kind {
        case .help: content.help(text)
        case .label: content.accessibilityLabel(text)
        case .value: content.accessibilityValue(text)
        case .hint: content.accessibilityHint(text)
        case .title: content.navigationTitle(text)
        }
    }
}

struct LanguagePicker: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.defaultLanguage
    @Environment(\.locale) private var locale
    var title: LocalizedMessage = "界面语言 / Language"
    var settingsRow = false

    var body: some View {
        Group {
            if settingsRow {
                Menu {
                    picker.pickerStyle(.inline)
                } label: {
                    HStack(spacing: 14) {
                        SettingsIcon(systemImage: "globe")
                        MessageText(title).font(.body.weight(.medium)).foregroundStyle(ChirpTheme.ink)
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            name(language)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold)).accessibilityHidden(true)
                        }
                        .foregroundStyle(ChirpTheme.secondary)
                    }
                    .padding(.vertical, 6).frame(minHeight: 48).contentShape(.rect)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .messageAccessibilityLabel(title).accessibilityValue(name(language))
            } else {
                picker.pickerStyle(.menu)
            }
        }
        .accessibilityIdentifier("app-language-picker")
    }

    private var picker: some View {
        Picker(selection: Binding(get: { language }, set: { value in
            language = value
            ClientLog.shared.record(.settings, "changeLanguage")
        })) {
            ForEach(AppLanguage.allCases, id: \.self) { option in name(option).tag(option) }
        } label: {
            MessageLabel(title, systemImage: "globe")
        }
    }

    private func name(_ option: AppLanguage) -> Text {
        switch option {
        case .simplifiedChinese: Text(verbatim: "简体中文")
        case .english: Text(verbatim: "English")
        case .system: Text(verbatim: LocalizedMessage("跟随系统").localized(in: locale))
        }
    }
}

struct MessageText: View {
    @Environment(\.locale) private var locale
    let message: LocalizedMessage

    init(_ message: LocalizedMessage) { self.message = message }

    var body: some View { Text(verbatim: message.localized(in: locale)) }
}

struct MessageLabel: View {
    let message: LocalizedMessage
    let systemImage: String

    init(_ message: LocalizedMessage, systemImage: String) {
        self.message = message; self.systemImage = systemImage
    }

    var body: some View { Label { MessageText(message) } icon: { Image(systemName: systemImage) } }
}

struct FailureText: View {
    @Environment(\.locale) private var locale
    let failure: ClientFailure

    init(_ failure: ClientFailure) { self.failure = failure }

    var body: some View { Text(verbatim: failure.localized(in: locale)) }
}
