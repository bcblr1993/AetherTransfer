import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public static let preferenceKey = "displayLanguage"
    public static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") ?? .system
    }
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        guard self == .system else { return self }
        for language in preferredLanguages {
            if language.hasPrefix("zh") { return .simplifiedChinese }
            if language.hasPrefix("en") { return .english }
        }
        return .english
    }
    public var locale: Locale { Locale(identifier: resolved().rawValue) }
}

/// Explicit language bundles allow an in-app language change without restarting
/// sessions. Keys are developer-owned UI text, never file names or server data.
public enum L10n {
    static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AetherTransfer_AetherTransferCore.bundle"),
           let bundled = Bundle(url: url) { return bundled }
        return Bundle.module
    }()
    private static let languages: [AppLanguage: Bundle] = {
        Dictionary(uniqueKeysWithValues: [AppLanguage.simplifiedChinese, .english].compactMap { language in
            guard let url = resources.url(forResource: language.rawValue, withExtension: "lproj"),
                  let bundle = Bundle(url: url) else { return nil }
            return (language, bundle)
        })
    }()

    public static func text(_ key: String, language: AppLanguage? = nil) -> String {
        let selected = (language ?? .current).resolved()
        return languages[selected]?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
    }

    public static func format(_ key: String, _ arguments: String...) -> String {
        format(key, arguments: arguments)
    }

    public static func format(_ key: String, arguments: [String], language: AppLanguage? = nil) -> String {
        String(format: text(key, language: language), locale: (language ?? .current).locale,
               arguments: arguments.map { $0 as CVarArg })
    }
}
