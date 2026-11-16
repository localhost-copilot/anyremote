import AppKit
import CryptoKit
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Dock")

extension Notification.Name {
    /// A mirror opened, closed or changed its title.
    static let mirrorsChanged = Notification.Name("AnyRemoteMirrorsChanged")
}

/// Gives each remote app with windows mirrored here its own Dock tile and
/// app switcher entry, like Parallels' Coherence mode.
///
/// macOS gives a process one Dock tile, so each remote app gets a small
/// stand-in app (`DockProxy/main.swift`) with the app's icon (badged) and
/// name, kept in the Applications folder (`RemoteAppBundles`). Clicking it,
/// or choosing it with ⌘Tab, brings that app's mirrors forward; its Dock
/// menu lists them; Quit closes them on this Mac only. Opened from
/// Spotlight, the Apps launcher or a Dock icon kept in the Dock, it asks for
/// the app to be opened on its Mac.
@MainActor
final class DockProxies {
    static let enabledKey = "ShowsRemoteAppsInDock"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if !newValue { RemoteAppBundles.removeAll() }
            NotificationCenter.default.post(name: .mirrorsChanged, object: nil)
        }
    }

    private final class Proxy {
        let id: String
        var url: URL?
        var application: NSRunningApplication?
        var mirrors: [MirrorWindowController] = []
        /// The badge the app shows on its Dock icon on the other Mac.
        var badge = ""
        /// Opened by the person (Spotlight, a Dock icon) and waiting for its
        /// app's window: kept running until then, without windows.
        var waitingUntil: Date?
        init(id: String) { self.id = id }
    }

    private let viewer: () -> ViewerModel
    private let parentID = Bundle.main.bundleIdentifier ?? "com.localhost-copilot.anyremote"
    private let center = DistributedNotificationCenter.default()
    private var proxies: [String: Proxy] = [:]
    /// Groups whose icon was asked for with a fresh window listing.
    private var iconRefreshes: Set<String> = []
    private var scheduled = false

    init(viewer: @escaping () -> ViewerModel) {
        self.viewer = viewer
        NotificationCenter.default.addObserver(forName: .mirrorsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        for event in ["ready", "activate", "focus", "closeAll"] {
            center.addObserver(forName: name(event), object: nil, queue: .main) { [weak self] note in
                let id = note.object as? String
                let window = note.userInfo?["window"] as? Int
                MainActor.assumeIsolated {
                    guard let id else { return }
                    self?.handle(event, id: id, window: window)
                }
            }
        }
        center.addObserver(forName: name("open"), object: nil, queue: .main) { [weak self] note in
            let id = note.object as? String
            let host = note.userInfo?["host"] as? String
            let application = note.userInfo?["application"] as? String
            let bundle = note.userInfo?["bundle"] as? String
            MainActor.assumeIsolated {
                guard let id, let host, let application else { return }
                self?.open(id: id, hostID: host, application: application, bundleIdentifier: bundle)
            }
        }
        RemoteAppBundles.removeLegacyBundles()
    }

    private func name(_ event: String) -> Notification.Name { .init("\(parentID).dock.\(event)") }

    private func post(_ event: String, to id: String, _ userInfo: [String: Any]? = nil) {
        center.postNotificationName(name(event), object: id, userInfo: userInfo, deliverImmediately: true)
    }

    func quitAll() {
        for id in proxies.keys { post("quit", to: id) }
        proxies.removeAll()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.sync()
            }
        }
    }

    // MARK: Groups

    private func sync() {
        guard Self.isEnabled else { return quitAll() }
        var groups: [String: (connection: HostConnection, application: String, mirrors: [MirrorWindowController])] = [:]
        for connection in viewer().connections.values {
            let host = Self.hostID(of: connection)
            for mirror in connection.openMirrors {
                let application = mirror.stream.applicationName
                let id = Self.proxyID(host: host, application: application)
                groups[id, default: (connection, application, [])].mirrors.append(mirror)
            }
        }
        for (id, proxy) in proxies where groups[id] == nil {
            if let waitingUntil = proxy.waitingUntil, waitingUntil > Date() { continue }
            post("quit", to: id)
            proxies[id] = nil
        }
        for (id, group) in groups {
            let mirrors = group.mirrors.sorted { $0.windowID < $1.windowID }
            let badge = Self.badge(for: group.application, in: group.connection)
            if let proxy = proxies[id] {
                proxy.mirrors = mirrors
                proxy.badge = badge
                proxy.waitingUntil = nil
                sendUpdate(proxy)
                continue
            }
            let icon = Self.icon(for: group.application, in: group.connection)
            if icon == nil, !iconRefreshes.contains(id) {
                // A window opened by itself may not be in the listing yet.
                iconRefreshes.insert(id)
                Task { [weak self] in
                    await group.connection.refresh(thumbnails: false)
                    self?.schedule()
                }
                continue
            }
            let proxy = Proxy(id: id)
            proxy.mirrors = mirrors
            proxy.badge = badge
            proxies[id] = proxy
            let bundle = group.connection.listing?.windows.first { $0.applicationName == group.application }?
                .bundleIdentifier
            launch(proxy, identity: .init(id: id, hostID: Self.hostID(of: group.connection),
                                          hostName: group.connection.hostName, application: group.application,
                                          bundleIdentifier: bundle), icon: icon)
        }
    }

    /// The Mac's own ID once connected, so the stand-ins of a Mac added by
    /// address are the same as when it is found nearby.
    private static func hostID(of connection: HostConnection) -> String {
        connection.welcome?.hostID ?? connection.target.hostID ?? connection.target.id
    }

    private static func proxyID(host: String, application: String) -> String {
        let digest = SHA256.hash(data: Data("\(host)|\(application)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func icon(for application: String, in connection: HostConnection) -> Data? {
        guard let listing = connection.listing else { return nil }
        let bundle = listing.windows.first { $0.applicationName == application && $0.bundleIdentifier != nil }?
            .bundleIdentifier
        return bundle.flatMap { connection.windowIcons[$0] }
    }

    /// The app's Dock badge on the host, matched by bundle when the window
    /// listing knows it, else by name.
    private static func badge(for application: String, in connection: HostConnection) -> String {
        let bundle = connection.listing?.windows.first { $0.applicationName == application }?.bundleIdentifier
        let badge = connection.badges.first { bundle != nil && $0.bundleIdentifier == bundle }
            ?? connection.badges.first { $0.applicationName == application }
        return badge?.label ?? ""
    }

    private func sendUpdate(_ proxy: Proxy) {
        let windows: [[Any]] = proxy.mirrors.map { mirror in
            let title = mirror.stream.title.isEmpty ? mirror.stream.applicationName : mirror.stream.title
            return [Int(mirror.windowID), title]
        }
        post("update", to: proxy.id, ["windows": windows, "badge": proxy.badge,
                                       "closeAllTitle": String(localized: "Close All on This Mac")])
    }

    // MARK: Proxy events

    private func handle(_ event: String, id: String, window: Int?) {
        guard let proxy = proxies[id] else {
            // A proxy left over from an earlier run.
            if event == "ready" { post("quit", to: id) }
            return
        }
        switch event {
        case "ready":
            sendUpdate(proxy)
        case "activate":
            Self.bringForward(proxy.mirrors)
        case "focus":
            Self.bringForward(proxy.mirrors.filter { Int($0.windowID) == window })
        case "closeAll":
            for mirror in proxy.mirrors { mirror.close() }
        default:
            break
        }
    }

    // MARK: Opening from the Applications folder

    /// A stand-in was opened by the person: open its app on its Mac, or
    /// bring its windows forward when they are here already.
    private func open(id: String, hostID: String, application: String, bundleIdentifier: String?) {
        log.notice("stand-in opened for \(application, privacy: .public)")
        if let proxy = proxies[id], !proxy.mirrors.isEmpty {
            sendUpdate(proxy)
            Self.bringForward(proxy.mirrors)
            return
        }
        let proxy = proxies[id] ?? Proxy(id: id)
        proxy.waitingUntil = Date().addingTimeInterval(30)
        proxies[id] = proxy
        // Answers the stand-in, which stops asking.
        sendUpdate(proxy)
        DispatchQueue.main.asyncAfter(deadline: .now() + 31) { [weak self] in
            MainActor.assumeIsolated { self?.schedule() }
        }
        Task { await openRemote(id: id, hostID: hostID, application: application, bundleIdentifier: bundleIdentifier) }
    }

    private func openRemote(id: String, hostID: String, application: String, bundleIdentifier: String?) async {
        let model = viewer()
        let saved = model.saved.first { $0.id == hostID }
        let hostName = saved?.name ?? hostID
        guard let target = model.myMacs.first(where: { $0.hostID == hostID || $0.savedID == hostID }) else {
            return failOpening(id: id, application: application, hostName: hostName,
                               reason: String(localized: "This Mac is no longer paired with it."))
        }
        if model.connection(for: target)?.state != .connected { await model.connect(target) }
        guard let connection = model.connection(for: target), connection.state == .connected else {
            return failOpening(id: id, application: application, hostName: target.name,
                               reason: FriendlyText.message(model.lastError ?? "Couldn't connect."))
        }
        let open = connection.openMirrors.filter { $0.stream.applicationName == application }
        guard open.isEmpty else { return Self.bringForward(open) }
        await connection.loadApplications()
        let applications = connection.offeredApplications
        guard let match = applications.first(where: { bundleIdentifier != nil && $0.bundleIdentifier == bundleIdentifier })
                ?? applications.first(where: { $0.name == application }) else {
            return failOpening(id: id, application: application, hostName: connection.hostName,
                               reason: String(localized: "The app isn’t installed there anymore."))
        }
        model.launch(match, on: connection, keepPicker: false)
    }

    private func failOpening(id: String, application: String, hostName: String, reason: String) {
        log.error("stand-in for \(application, privacy: .public) couldn't open: \(reason, privacy: .public)")
        post("quit", to: id)
        proxies[id] = nil
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn’t open “\(application)” on “\(hostName)”")
        alert.informativeText = reason
        alert.runModal()
    }

    /// Shows the mirrors in their current order, the frontmost one key.
    static func bringForward(_ mirrors: [MirrorWindowController]) {
        let windows = mirrors.compactMap(\.window)
        guard !windows.isEmpty else { return }
        NSApp.activate()
        let order = NSApp.orderedWindows
        let sorted = windows.sorted {
            (order.firstIndex(of: $0) ?? .max) > (order.firstIndex(of: $1) ?? .max)
        }
        for window in sorted {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFront(nil)
        }
        sorted.last?.makeKeyAndOrderFront(nil)
    }

    // MARK: Bundles

    private func launch(_ proxy: Proxy, identity: RemoteAppBundles.Identity, icon: Data?) {
        let url: URL
        do {
            url = try RemoteAppBundles.make(identity, icon: icon)
        } catch {
            log.error("dock proxy bundle failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        proxy.url = url
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        // Not opened by the person: nothing to open on the other Mac.
        configuration.arguments = ["-AnyRemoteLaunched"]
        let id = proxy.id
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] application, error in
            if let error { log.error("dock proxy launch failed: \(error.localizedDescription, privacy: .public)") }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if let proxy = self?.proxies[id] {
                        proxy.application = application
                    } else {
                        application?.terminate()
                    }
                }
            }
        }
    }

}
