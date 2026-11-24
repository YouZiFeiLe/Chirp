import Foundation

enum AppLanguage: String, CaseIterable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case system = "system"

    static let preferenceKey = "appLanguage"
    static let defaultLanguage: AppLanguage = .simplifiedChinese

    static func load(from defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? defaultLanguage
    }

    func save(to defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.preferenceKey) }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            let language = Locale(identifier: identifier).language
            if language.languageCode?.identifier == "en" { return .english }
            if language.languageCode?.identifier == "zh", language.script?.identifier == "Hans" {
                return .simplifiedChinese
            }
        }
        return .english
    }

    var locale: Locale { Locale(identifier: resolved().rawValue) }
}

enum AppLocalization {
    static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }

    static func bundle(for locale: Locale) -> Bundle {
        let language = AppLanguage.system.resolved(preferredLanguages: [locale.identifier])
        if let url = resourceBundle.url(forResource: language.rawValue, withExtension: "lproj"),
           let bundle = Bundle(url: url) { return bundle }
        if let url = resourceBundle.url(forResource: "en", withExtension: "lproj"),
           let bundle = Bundle(url: url) { return bundle }
        return resourceBundle
    }
}

/// Deferred UI text. Interpolated app messages resolve in the same language;
/// interpolated names, addresses and other String values remain verbatim.
struct LocalizedMessage: Equatable, Sendable, ExpressibleByStringInterpolation {
    let key: String
    private let arguments: [Argument]

    fileprivate indirect enum Argument: Equatable, Sendable {
        case string(String), integer(Int64), message(LocalizedMessage)

        func value(in locale: Locale) -> any CVarArg {
            switch self {
            case .string(let value): value
            case .integer(let value): value
            case .message(let value): value.localized(in: locale)
            }
        }
    }

    init(stringLiteral value: String) { key = value; arguments = [] }

    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    func localized(in locale: Locale) -> String {
        let english = AppLocalization.bundle(for: AppLanguage.english.locale)
            .localizedString(forKey: key, value: key, table: "Localizable")
        let format = AppLocalization.bundle(for: locale).localizedString(forKey: key, value: english, table: "Localizable")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments.map { $0.value(in: locale) })
    }

    struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var key = ""
        fileprivate var arguments: [Argument] = []

        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }

        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation(_ value: String) { key += "%@"; arguments.append(.string(value)) }
        mutating func appendInterpolation(_ value: Int) { key += "%lld"; arguments.append(.integer(Int64(value))) }
        mutating func appendInterpolation(_ value: LocalizedMessage) { key += "%@"; arguments.append(.message(value)) }
    }
}
