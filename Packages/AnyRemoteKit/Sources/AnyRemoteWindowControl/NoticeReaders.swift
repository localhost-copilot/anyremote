import AppKit
import ApplicationServices

/// A notification banner on screen, read through Accessibility.
public struct NotificationBanner: Equatable, Sendable {
    /// Notification Center's identifier for the banner (a UUID), stable
    /// while it is shown.
    public var id: String
    public var applicationName: String
    public var title: String
    public var subtitle: String
    public var body: String
}

/// Reads the banners Notification Center shows, and opens one.
///
/// Notification Center (`com.apple.notificationcenterui`) draws each banner
/// as an element with subrole `AXNotificationCenterBanner` (alerts and
/// stacks have similar subroles), an identifier, `title`/`subtitle`/`body`
/// texts, and a description that starts with the app's name: "Mail, Anna,
/// Lunch?, See you at noon". Pressing it does what clicking the banner does.
/// Checked on macOS 27.
public enum NotificationBannerReader {
    static let bundleIdentifier = "com.apple.notificationcenterui"

    public static func read() -> [NotificationBanner] {
        guard let application = application() else { return [] }
        var banners: [NotificationBanner] = []
        var budget = 400
        for window in children(application) {
            collect(window, depth: 0, budget: &budget, into: &banners)
        }
        return banners
    }

    /// Presses the banner, if it is still shown. Returns whether it was.
    @discardableResult
    public static func open(id: String) -> Bool {
        guard let application = application() else { return false }
        var budget = 400
        for window in children(application) {
            if let banner = find(id, in: window, depth: 0, budget: &budget) {
                return AXUIElementPerformAction(banner, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    /// The app's name from a banner's description, which lists the app's
    /// name and then the banner's texts, comma-separated.
    public static func applicationName(description: String, title: String, subtitle: String,
                                       body: String) -> String? {
        let texts = [title, subtitle, body].filter { !$0.isEmpty }
        if !texts.isEmpty {
            let suffix = ", " + texts.joined(separator: ", ")
            if description.hasSuffix(suffix) {
                let name = String(description.dropLast(suffix.count))
                return name.isEmpty ? nil : name
            }
        }
        // Texts the description words differently: the app's name comes first.
        guard let name = description.components(separatedBy: ", ").first, !name.isEmpty,
              name != description || texts.isEmpty else { return nil }
        return name
    }

    private static func application() -> AXUIElement? {
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        else { return nil }
        let application = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        return application
    }

    private static func isBanner(_ element: AXUIElement) -> Bool {
        guard let subrole = string(element, kAXSubroleAttribute), subrole.hasPrefix("AXNotificationCenter"),
              !subrole.hasSuffix("Stack") else { return false }
        return !(string(element, kAXIdentifierAttribute) ?? "").isEmpty
    }

    private static func collect(_ element: AXUIElement, depth: Int, budget: inout Int,
                                into banners: inout [NotificationBanner]) {
        guard depth < 10, budget > 0 else { return }
        budget -= 1
        if isBanner(element), let banner = banner(element) {
            banners.append(banner)
            return
        }
        for child in children(element) { collect(child, depth: depth + 1, budget: &budget, into: &banners) }
    }

    private static func find(_ id: String, in element: AXUIElement, depth: Int, budget: inout Int) -> AXUIElement? {
        guard depth < 10, budget > 0 else { return nil }
        budget -= 1
        if isBanner(element), string(element, kAXIdentifierAttribute) == id { return element }
        for child in children(element) {
            if let found = find(id, in: child, depth: depth + 1, budget: &budget) { return found }
        }
        return nil
    }

    private static func banner(_ element: AXUIElement) -> NotificationBanner? {
        guard let id = string(element, kAXIdentifierAttribute) else { return nil }
        var texts: [String: String] = [:]
        for child in children(element) {
            guard let identifier = string(child, kAXIdentifierAttribute),
                  ["title", "subtitle", "body"].contains(identifier) else { continue }
            texts[identifier] = string(child, kAXValueAttribute) ?? ""
        }
        let title = texts["title"] ?? "", subtitle = texts["subtitle"] ?? "", body = texts["body"] ?? ""
        guard !(title.isEmpty && body.isEmpty),
              let name = applicationName(description: string(element, kAXDescriptionAttribute) ?? "",
                                         title: title, subtitle: subtitle, body: body) else { return nil }
        return NotificationBanner(id: id, applicationName: name, title: title, subtitle: subtitle, body: body)
    }
}

/// A badge on an app's Dock icon.
public struct DockBadge: Equatable, Sendable {
    public var applicationName: String
    /// The app's bundle, as the Dock knows it.
    public var url: URL?
    public var label: String
}

/// Reads the badges on the Dock's app icons: each Dock item has an
/// `AXStatusLabel` with the badge's text. Running apps are always in the
/// Dock, so their badges are all here.
public enum DockBadgeReader {
    public static func read() -> [DockBadge] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [] }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var badges: [DockBadge] = []
        for list in children(application) {
            for item in children(list) {
                guard string(item, kAXSubroleAttribute) == "AXApplicationDockItem",
                      let label = string(item, "AXStatusLabel"), !label.isEmpty else { continue }
                var url: AnyObject?
                AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &url)
                badges.append(DockBadge(applicationName: string(item, kAXTitleAttribute) ?? "",
                                        url: url as? URL, label: label))
            }
        }
        return badges
    }
}

private func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
        return []
    }
    return value as? [AXUIElement] ?? []
}

private func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}
