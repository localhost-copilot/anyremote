import AnyRemoteWire
import ApplicationServices
import Foundation

/// Reads an application's menu bar through Accessibility and presses items.
///
/// One `AXUIElementCopyMultipleAttributeValues` call per item keeps a full
/// menu bar (a few hundred items) to a few tens of milliseconds.
public enum MenuBarReader {
    public static let maximumItems = 4000
    public static let maximumDepth = 5

    private static var attributes: CFArray { [
        kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemMarkCharAttribute, kAXMenuItemCmdCharAttribute,
        kAXMenuItemCmdModifiersAttribute, kAXChildrenAttribute, kAXRoleAttribute,
    ] as [CFString] as CFArray }

    public static func read(pid: pid_t) -> [MenuNode]? {
        // Our own menu bar holds the viewer's copy of the remote menus; reading
        // it back would mirror itself (only happens when mirroring this Mac's own windows).
        guard pid != getpid() else { return nil }
        guard let bar = menuBar(pid: pid) else { return nil }
        var budget = maximumItems
        return children(of: bar, depth: 0, budget: &budget)
    }

    /// Presses the item at `path` (indices from the menu bar down).
    @discardableResult
    public static func perform(pid: pid_t, path: [Int]) -> Bool {
        guard pid != getpid(), let bar = menuBar(pid: pid), let first = path.first else { return false }
        let barItems = elementChildren(bar)
        guard first >= 0, first < barItems.count else { return false }
        var item = barItems[first]
        for index in path.dropFirst() {
            guard let menu = elementChildren(item).first(where: { role(of: $0) == kAXMenuRole as String }) else {
                return false
            }
            let items = elementChildren(menu)
            guard index >= 0, index < items.count else { return false }
            item = items[index]
        }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// The items of an open menu (a menu bar item's).
    static func read(menu: AXUIElement) -> [MenuNode] {
        var budget = maximumItems
        return children(of: menu, depth: 1, budget: &budget)
    }

    /// Presses the item at `path` in an open menu.
    static func perform(in menu: AXUIElement, path: [Int]) -> Bool {
        var menu = menu
        var item: AXUIElement?
        for index in path {
            if let item {
                guard let submenu = elementChildren(item).first(where: { role(of: $0) == kAXMenuRole as String })
                else { return false }
                menu = submenu
            }
            let items = elementChildren(menu)
            guard index >= 0, index < items.count else { return false }
            item = items[index]
        }
        guard let item else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private static func menuBar(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elementChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return (value as? [AXUIElement]) ?? []
    }

    static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String
    }

    /// Items of a menu bar (depth 0) or of a menu.
    private static func children(of element: AXUIElement, depth: Int, budget: inout Int) -> [MenuNode] {
        var nodes: [MenuNode] = []
        for child in elementChildren(element) {
            guard budget > 0 else { break }
            budget -= 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(child, attributes, [], &values) == .success,
                  let array = values as? [Any], array.count == 7 else { continue }
            func string(_ index: Int) -> String? { array[index] as? String }
            let title = string(0) ?? ""
            let enabled = (array[1] as? Bool) ?? true
            let mark = string(2).flatMap { $0.isEmpty ? nil : $0 }
            let keyEquivalent = string(3) ?? ""
            let modifiers = (array[4] as? Int) ?? 0
            let grandchildren = (array[5] as? [AXUIElement]) ?? []
            var node = MenuNode(title: title, isEnabled: enabled, isSeparator: title.isEmpty && depth > 0,
                                mark: mark, keyEquivalent: keyEquivalent, keyModifiers: modifiers)
            if depth < maximumDepth, let menu = grandchildren.first, role(of: menu) == kAXMenuRole as String {
                node.children = children(of: menu, depth: depth + 1, budget: &budget)
                if node.children.isEmpty && depth == 0 { node.isSeparator = false }
            }
            nodes.append(node)
        }
        return nodes
    }
}
