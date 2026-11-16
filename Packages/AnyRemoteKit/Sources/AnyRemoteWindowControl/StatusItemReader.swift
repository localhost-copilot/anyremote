import AnyRemoteWire
import AppKit
import ApplicationServices

/// A menu bar item on the right of the menu bar, as Accessibility knows it.
public struct StatusItemInfo: Sendable {
    public var id: String
    public var pid: pid_t
    public var applicationName: String
    public var bundleIdentifier: String?
    public var title: String
    /// Global points, top-left origin.
    public var frame: CGRect
}

/// Lists the menu bar items of every app (each app's `AXExtrasMenuBar`),
/// clicks them, and reads and uses the menus they open.
///
/// Items are named `<pid>:<identifier>` when the app gives them an
/// identifier, else `<pid>#<index>`. A click is `AXPress`; an app whose item
/// opens a menu runs that menu's tracking loop inside the press, so the
/// press only returns when the call times out, with the menu open; it is
/// read as the item's `AXMenu` child.
public enum StatusItemReader {
    /// The items, right to left as on screen; items that can't be clicked
    /// (the clock, Control Center's own) and those of `excludedPIDs` left out.
    public static func list(excludingPIDs excludedPIDs: Set<pid_t>) -> [StatusItemInfo] {
        var items: [StatusItemInfo] = []
        let menuBars = displayTops()
        for application in NSWorkspace.shared.runningApplications
        where application.activationPolicy != .prohibited && !excludedPIDs.contains(application.processIdentifier) {
            let pid = application.processIdentifier
            for (index, element) in elements(pid: pid).enumerated() {
                guard actions(element).contains(kAXPressAction as String), let frame = frame(element),
                      menuBars.contains(where: { $0.minX <= frame.midX && frame.midX < $0.maxX
                          && abs(frame.minY - $0.minY) < 12 }) else { continue }
                let identifier = string(element, kAXIdentifierAttribute) ?? ""
                let title = [string(element, kAXDescriptionAttribute), string(element, kAXTitleAttribute)]
                    .compactMap { $0 }.first { !$0.isEmpty } ?? ""
                items.append(StatusItemInfo(
                    id: identifier.isEmpty ? "\(pid)#\(index)" : "\(pid):\(identifier)", pid: pid,
                    applicationName: application.localizedName ?? "", bundleIdentifier: application.bundleIdentifier,
                    title: title, frame: frame))
            }
        }
        return items.sorted { $0.frame.minX > $1.frame.minX }
    }

    public static func pid(of id: String) -> pid_t? {
        guard let end = id.firstIndex(where: { $0 == ":" || $0 == "#" }) else { return nil }
        return pid_t(id[..<end])
    }

    /// Clicks the item. Returns false only when it couldn't be found.
    public static func press(_ id: String) -> Bool {
        guard let element = element(id) else { return false }
        AXUIElementSetMessagingTimeout(element, 0.25)
        // A menu keeps the press from returning until it times out; the menu is open then.
        _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return true
    }

    /// The menu the item has open, if it opened one.
    public static func openMenu(_ id: String) -> [MenuNode]? {
        guard let menu = menuElement(id) else { return nil }
        let nodes = MenuBarReader.read(menu: menu)
        return nodes.isEmpty ? nil : nodes
    }

    /// Chooses the item at `path` in the open menu, or closes it (nil).
    @discardableResult
    public static func finishMenu(_ id: String, path: [Int]?) -> Bool {
        guard let menu = menuElement(id) else { return false }
        AXUIElementSetMessagingTimeout(menu, 0.25)
        if let path { return MenuBarReader.perform(in: menu, path: path) }
        return AXUIElementPerformAction(menu, kAXCancelAction as CFString) == .success
    }

    /// Each display's top edge (menu bar items sit there; Screen Sharing's
    /// indicator, for one, is an "item" elsewhere).
    private static func displayTops() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    // MARK: Elements

    private static func elements(pid: pid_t) -> [AXUIElement] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var bar: AnyObject?
        guard AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        return MenuBarReader.elementChildren(bar as! AXUIElement)
    }

    private static func element(_ id: String) -> AXUIElement? {
        guard let pid = pid(of: id) else { return nil }
        let elements = elements(pid: pid)
        if let hash = id.firstIndex(of: "#"), let index = Int(id[id.index(after: hash)...]) {
            return elements.indices.contains(index) ? elements[index] : nil
        }
        let identifier = String(id[id.index(after: id.firstIndex(of: ":")!)...])
        return elements.first { string($0, kAXIdentifierAttribute) == identifier }
    }

    private static func menuElement(_ id: String) -> AXUIElement? {
        guard let element = element(id) else { return nil }
        return MenuBarReader.elementChildren(element).first { MenuBarReader.role(of: $0) == kAXMenuRole as String }
    }

    private static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return names as? [String] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var position: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }
}
