import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return L10n.isEnglish ? "Follow System" : "跟随系统"
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}

public enum L10n {
    private static let lock = NSLock()
    private static let userDefaultsKey = "com.aethernative.AetherTransfer.language"
    nonisolated(unsafe) private static var _overrideLanguage: AppLanguage?

    public static var currentPreference: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let override = _overrideLanguage { return override }
            if let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
               let lang = AppLanguage(rawValue: raw) {
                return lang
            }
            return .system
        }
        set {
            lock.lock()
            _overrideLanguage = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey)
            lock.unlock()
        }
    }

    public static var isEnglish: Bool {
        switch currentPreference {
        case .en:
            return true
        case .zhHans:
            return false
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "zh-hans"
            return preferred.hasPrefix("en")
        }
    }

    public static func tr(_ zh: String, _ en: String) -> String {
        isEnglish ? en : zh
    }
}
