import AppKit

/// The interface language. English unless the user picks otherwise; the
/// choice is applied through the app's own `AppleLanguages` default, which
/// takes effect at the next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case system

    var id: String { rawValue }
    private static let key = "AnyRemoteLanguage"

    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    /// Call before anything loads localized resources.
    static func applyAtLaunch() { current.apply() }

    static func choose(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: key)
        language.apply()
    }

    private func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// The language that is in effect now (it changes only at launch).
    static var running: String { Bundle.main.preferredLocalizations.first ?? "en" }
}
