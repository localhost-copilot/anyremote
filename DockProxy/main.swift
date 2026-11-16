import AppKit

/// Stands in for one remote app in the Dock and the app switcher, the way
/// Parallels' Coherence apps do. AnyRemote generates a bundle around this
/// executable for each remote app with windows mirrored here (its icon and
/// name come from the bundle) and talks to it with distributed notifications
/// named `<AnyRemote bundle ID>.dock.<event>`, the object being the proxy ID:
///
///   to AnyRemote: ready, activate, focus {window}, closeAll
///   to the proxy: update {windows: [[id, title]], badge, closeAllTitle}, quit
@MainActor
final class DockProxy: NSObject, NSApplicationDelegate {
    private let id: String
    private let parentBundleID: String
    private let center = DistributedNotificationCenter.default()
    private var windows: [(id: Int, title: String)] = []
    private var closeAllTitle = "Close All on This Mac"
    private var quitByParent = false
    private var parentWatch: DispatchSourceProcess?

    init(id: String, parentBundleID: String) {
        self.id = id
        self.parentBundleID = parentBundleID
    }

    private func name(_ event: String) -> Notification.Name { .init("\(parentBundleID).dock.\(event)") }

    private func post(_ event: String, _ userInfo: [String: Any]? = nil) {
        center.postNotificationName(name(event), object: id, userInfo: userInfo, deliverImmediately: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        center.addObserver(self, selector: #selector(update(_:)), name: name("update"), object: id,
                           suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(quit(_:)), name: name("quit"), object: id,
                           suspensionBehavior: .deliverImmediately)
        // Leave with AnyRemote, however it ends.
        if let parent = NSRunningApplication.runningApplications(withBundleIdentifier: parentBundleID).first {
            let source = DispatchSource.makeProcessSource(identifier: parent.processIdentifier, eventMask: .exit,
                                                          queue: .main)
            source.setEventHandler { exit(0) }
            source.resume()
            parentWatch = source
        } else {
            exit(0)
        }
        post("ready")
    }

    @objc private func update(_ note: Notification) {
        let list = note.userInfo?["windows"] as? [[Any]] ?? []
        windows = list.compactMap { entry in
            guard entry.count == 2, let id = entry[0] as? Int, let title = entry[1] as? String else { return nil }
            return (id, title)
        }
        if let title = note.userInfo?["closeAllTitle"] as? String { closeAllTitle = title }
        // The remote app's own Dock badge (unread count), or none.
        if let badge = note.userInfo?["badge"] as? String {
            let label = badge.isEmpty ? nil : badge
            if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        }
    }

    @objc private func quit(_ note: Notification) {
        quitByParent = true
        NSApp.terminate(nil)
    }

    /// Clicked in the Dock or chosen in the app switcher: AnyRemote shows the windows.
    func applicationDidBecomeActive(_ notification: Notification) {
        activateParent()
        post("activate")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        activateParent()
        post("activate")
        return false
    }

    private func activateParent() {
        if let parent = NSRunningApplication.runningApplications(withBundleIdentifier: parentBundleID).first {
            NSApp.yieldActivation(to: parent)
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for window in windows {
            let item = NSMenuItem(title: window.title.isEmpty ? "—" : window.title,
                                  action: #selector(focus(_:)), keyEquivalent: "")
            item.tag = window.id
            item.target = self
            menu.addItem(item)
        }
        if !windows.isEmpty { menu.addItem(.separator()) }
        let close = NSMenuItem(title: closeAllTitle, action: #selector(closeAll(_:)), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func focus(_ sender: NSMenuItem) {
        activateParent()
        post("focus", ["window": sender.tag])
    }

    @objc private func closeAll(_ sender: Any?) {
        post("closeAll")
    }

    /// Quit from the Dock closes the windows on this Mac only; the app keeps
    /// running on the other Mac.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !quitByParent { post("closeAll") }
        return .terminateNow
    }
}

let info = Bundle.main.infoDictionary ?? [:]
guard let id = info["AnyRemoteProxyID"] as? String, let parent = info["AnyRemoteParentBundleID"] as? String else {
    FileHandle.standardError.write(Data("AnyRemoteDockProxy runs inside a bundle AnyRemote generates.\n".utf8))
    exit(1)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { DockProxy(id: id, parentBundleID: parent) }
app.delegate = delegate
app.run()
