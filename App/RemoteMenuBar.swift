import AnyRemoteWire
import AppKit

/// Rebuilds the host application's menu bar as native menus while its
/// mirror is the key window. Choosing an item presses it on the host
/// through Accessibility; key equivalents are shown but typing them goes to
/// the host directly (see `KeyForwarder`).
@MainActor
final class RemoteMenuBar: NSObject, NSMenuDelegate {
    private var installedItems: [NSMenuItem] = []
    private var hiddenItems: [NSMenuItem] = []
    private weak var mirror: MirrorWindowController?
    static let ownMenuTitle = String(localized: "Remote")

    /// Replaces the remote menus in `mainMenu` (inserted after the app menu).
    func install(for mirror: MirrorWindowController?, in mainMenu: NSMenu) {
        for item in installedItems { mainMenu.removeItem(item) }
        installedItems.removeAll()
        for item in hiddenItems { item.isHidden = false }
        hiddenItems.removeAll()
        self.mirror = mirror
        guard let mirror else { return }
        // While the host app's menus are shown, ours step aside except the
        // app menu and 远程 (our ⌃⌥⌘ commands), so nothing appears twice.
        guard !mirror.remoteMenus.isEmpty else { return }
        for item in mainMenu.items.dropFirst() where item.submenu?.title != RemoteMenuBar.ownMenuTitle {
            item.isHidden = true
            hiddenItems.append(item)
        }
        // Index 0 is the host's Apple menu; ours stays in charge of that.
        for (index, node) in mirror.remoteMenus.enumerated() where index > 0 && !node.children.isEmpty {
            let item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: node.title)
            menu.autoenablesItems = false
            menu.delegate = self
            build(node.children, into: menu, path: [index])
            item.submenu = menu
            mainMenu.insertItem(item, at: 1 + installedItems.count)
            installedItems.append(item)
        }
    }

    private func build(_ nodes: [MenuNode], into menu: NSMenu, path: [Int]) {
        for (index, node) in nodes.enumerated() {
            if node.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: node.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = node.isEnabled
            item.representedObject = path + [index]
            switch node.mark {
            case "✓", "✔": item.state = .on
            case "-", "•", "–": item.state = .mixed
            default: break
            }
            if !node.keyEquivalent.isEmpty {
                item.keyEquivalent = Self.keyEquivalent(node.keyEquivalent)
                item.keyEquivalentModifierMask = Self.modifiers(node.keyModifiers)
            }
            if !node.children.isEmpty {
                let submenu = NSMenu(title: node.title)
                submenu.autoenablesItems = false
                build(node.children, into: submenu, path: path + [index])
                item.submenu = submenu
                item.action = nil
            }
            menu.addItem(item)
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? [Int] else { return }
        mirror?.performMenuItem(path: path)
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Shown as last read; refreshed for the next opening.
        mirror?.refreshMenuBar()
    }

    /// AX key equivalent characters are uppercase letters; AppKit implies
    /// Shift for uppercase, so lowercase them.
    private static func keyEquivalent(_ character: String) -> String {
        switch character {
        case "\u{1B}": return "\u{1B}"
        default: return character.lowercased()
        }
    }

    /// kAXMenuItemModifier*: Command is implied unless kAXMenuItemModifierNoCommand (8).
    static func modifiers(_ ax: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if ax & 8 == 0 { flags.insert(.command) }
        if ax & 1 != 0 { flags.insert(.shift) }
        if ax & 2 != 0 { flags.insert(.option) }
        if ax & 4 != 0 { flags.insert(.control) }
        return flags
    }
}
