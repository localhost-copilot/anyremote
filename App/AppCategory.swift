import AnyRemoteWire

/// The broad groups the Apps grid filters by, as macOS's own Apps view does:
/// the App Store's many categories folded into a handful a row of chips can show.
enum AppCategory: String, CaseIterable, Identifiable {
    case developerTools, utilities, productivity, creativity, reading, entertainment, social, games, lifestyle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .developerTools: String(localized: "Developer Tools")
        case .utilities: String(localized: "Utilities")
        case .productivity: String(localized: "Productivity & Finance")
        case .creativity: String(localized: "Creativity")
        case .reading: String(localized: "Information & Reading")
        case .entertainment: String(localized: "Entertainment")
        case .social: String(localized: "Social")
        case .games: String(localized: "Games")
        case .lifestyle: String(localized: "Lifestyle")
        }
    }

    /// The group of an app's `LSApplicationCategoryType`, or nil for apps
    /// that declare none (they still appear when no group is chosen).
    init?(_ application: HostApplication) {
        guard let type = application.category?.lowercased(),
              let name = type.split(separator: ".").last.map(String.init) else { return nil }
        if name.hasSuffix("games") { self = .games; return }
        switch name {
        case "developer-tools": self = .developerTools
        case "utilities": self = .utilities
        case "productivity", "business", "finance": self = .productivity
        case "graphics-design", "photography", "video": self = .creativity
        case "news", "reference", "education", "weather", "books": self = .reading
        case "entertainment", "music": self = .entertainment
        case "social-networking": self = .social
        case "lifestyle", "healthcare-fitness", "medical", "travel", "sports", "navigation": self = .lifestyle
        default: return nil
        }
    }
}
