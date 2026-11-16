import AnyRemoteWire
import AppKit
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "StatusItems")

/// The other Mac's menu bar items (the right side of its menu bar: a VPN, a
/// utility, its input menu) in this Mac's menu bar, the way Parallels
/// brings Windows' notification area icons over.
///
/// While a Mac has windows open here, a display icon for it sits in this
/// Mac's menu bar. Its menu lists that Mac's items with their apps' icons.
/// Choosing one clicks it there: a menu it opens shows here as a native
/// menu under the icon, a popover or panel shows below the icon as it would
/// below the item, and a window comes as a mirror.
@MainActor
final class RemoteStatusItems: NSObject, NSMenuDelegate {
    static let shared = RemoteStatusItems()
    static let changed = Notification.Name("AnyRemoteRemoteStatusItemsChanged")
    private static let key = "ShowsRemoteStatusItems"

    static var isEnabled: Bool {
        // Off until turned on: an extra icon in the menu bar is something to ask for.
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    private final class Entry {
        let statusItem: NSStatusItem
        weak var connection: HostConnection?
        var items: [HostStatusItem] = []
        /// The item last clicked, which popups are placed under.
        var opened: HostStatusItem?
        init(statusItem: NSStatusItem, connection: HostConnection) {
            self.statusItem = statusItem
            self.connection = connection
        }
    }

    var connections: () -> [HostConnection] = { [] }
    /// Development: sees a menu that came back instead of showing it.
    var onMenu: ((String, [MenuNode]) -> Void)?
    /// Development: the popups shown.
    var onPopup: ((PopupWindowController) -> Void)?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var scheduled = false

    override init() {
        super.init()
        for name in [Notification.Name.mirrorsChanged, Self.changed] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
        }
    }

    func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.sync()
            }
        }
    }

    /// One icon per Mac with windows (or a desktop) open here.
    private func sync() {
        let wanted = Self.isEnabled ? connections().filter {
            $0.state == .connected && !($0.openMirrors.isEmpty && $0.openDesktops.isEmpty)
        } : []
        let ids = Set(wanted.map(ObjectIdentifier.init))
        for (id, entry) in entries where !ids.contains(id) {
            NSStatusBar.system.removeStatusItem(entry.statusItem)
            entries[id] = nil
        }
        for connection in wanted where entries[ObjectIdentifier(connection)] == nil {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: connection.hostName)
            statusItem.button?.toolTip = String(localized: "Menu Bar of “\(connection.hostName)”")
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            statusItem.menu = menu
            let entry = Entry(statusItem: statusItem, connection: connection)
            entries[ObjectIdentifier(connection)] = entry
            refresh(entry)
        }
    }

    // MARK: The icon's menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let entry = entries.values.first(where: { $0.statusItem.menu === menu }) else { return }
        fill(menu, from: entry)
        // Shown as last listed; the fresh list replaces it while the menu is open.
        refresh(entry)
    }

    private func refresh(_ entry: Entry) {
        guard let connection = entry.connection else { return }
        Task {
            guard let items = try? await connection.client.listStatusItems() else { return }
            entry.items = items
            if let menu = entry.statusItem.menu { fill(menu, from: entry) }
        }
    }

    private func fill(_ menu: NSMenu, from entry: Entry) {
        menu.removeAllItems()
        let header = NSMenuItem(title: entry.connection?.hostName ?? "", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if entry.items.isEmpty {
            let none = NSMenuItem(title: String(localized: "No Menu Bar Items"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for item in entry.items {
            let row = NSMenuItem(title: item.title.isEmpty ? item.applicationName : item.title,
                                 action: #selector(choose(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = item.id
            row.image = Self.picture(item)
            menu.addItem(row)
        }
    }

    /// The item's app icon, menu-sized.
    private static func picture(_ item: HostStatusItem) -> NSImage? {
        guard let data = item.image, let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = entries.values.first(where: { $0.items.contains { $0.id == id } }),
              let connection = entry.connection else { return }
        entry.opened = entry.items.first { $0.id == id }
        connection.client.send(.openStatusItem(id: id))
    }

    // MARK: What an item opened

    /// The item's menu is open on the other Mac: show it here, under the
    /// icon, and pass on the choice (or that there was none).
    func showMenu(_ nodes: [MenuNode], itemID: String, from connection: HostConnection) {
        if let onMenu {
            onMenu(itemID, nodes)
            connection.client.send(.performStatusItemMenu(id: itemID, path: nil))
            return
        }
        guard let entry = entries[ObjectIdentifier(connection)], let button = entry.statusItem.button else {
            connection.client.send(.performStatusItemMenu(id: itemID, path: nil))
            return
        }
        // Shown as the icon's own menu, so it opens from the icon (highlighted)
        // like any menu bar item's; then the icon's list comes back.
        let chooser = MenuChoice()
        let menu = NSMenu()
        menu.autoenablesItems = false
        RemoteMenuBuilder.build(nodes, into: menu, path: [], target: chooser, action: #selector(MenuChoice.choose(_:)))
        let list = entry.statusItem.menu
        menu.delegate = chooser
        chooser.onClose = { [weak entry] path in
            entry?.statusItem.menu = list
            log.notice("menu of \(itemID, privacy: .public) closed, chose \(path?.description ?? "nothing", privacy: .public)")
            connection.client.send(.performStatusItemMenu(id: itemID, path: path))
        }
        entry.statusItem.menu = menu
        button.performClick(nil)
    }

    /// Development: clicks an item as choosing it from the icon's menu would.
    func open(_ item: HostStatusItem, from connection: HostConnection) {
        entries[ObjectIdentifier(connection)]?.opened = item
        connection.client.send(.openStatusItem(id: item.id))
    }

    /// Where a popup the last clicked item opened goes on this Mac: below
    /// the icon, as far from it as the popup is from the item on the host
    /// (screen coordinates of its top-left corner).
    func popupOrigin(for frame: CGRect, from connection: HostConnection) -> NSPoint? {
        guard let entry = entries[ObjectIdentifier(connection)], let button = entry.statusItem.button,
              let window = button.window, let opened = entry.opened else { return nil }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        var x = icon.minX + (frame.minX - opened.frame.minX)
        let top = icon.minY - max(0, frame.minY - opened.frame.maxY)
        if let screen = window.screen?.visibleFrame {
            x = min(max(x, screen.minX + 4), screen.maxX - frame.width - 4)
        }
        return NSPoint(x: x, y: top)
    }
}

/// Remembers which item of a remote menu was chosen, and answers once it
/// has closed. The chosen item's action arrives just after `menuDidClose`.
@MainActor
private final class MenuChoice: NSObject, NSMenuDelegate {
    var path: [Int]?
    var onClose: (([Int]?) -> Void)?

    @objc func choose(_ sender: NSMenuItem) { path = sender.representedObject as? [Int] }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // Kept alive by the menu's items until then.
                self.onClose?(self.path)
                self.onClose = nil
            }
        }
    }
}
