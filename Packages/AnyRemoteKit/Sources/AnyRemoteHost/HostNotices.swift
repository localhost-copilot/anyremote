import AnyRemoteWindowControl
import AnyRemoteWire
import AppKit
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Notices")

/// Watches the host's notification banners and Dock badges for the viewers
/// that asked for them, the way Parallels shows a Windows app's
/// notifications on the Mac.
///
/// macOS has no API for another app's notifications, so this reads what
/// Notification Center and the Dock show, through Accessibility: banners
/// twice a second (a banner stays about five seconds), badges every two
/// seconds. Nothing is read while no viewer wants it. Notifications the
/// host doesn't show as banners (Focus, *None* style) don't reach viewers.
///
/// All state is confined to `queue`; Accessibility calls into a busy
/// Notification Center or Dock wait here, never on the host's queue.
final class HostNotices: @unchecked Sendable {
    private struct Subscriber {
        weak var session: HostSession?
        var subscription: NoticeSubscription
        /// Apps whose icon this viewer already has.
        var sentIcons: Set<String> = []
    }

    private let queue = DispatchQueue(label: "anyremote.notices", qos: .utility)
    // Queue-confined.
    private var subscribers: [UInt32: Subscriber] = [:]
    private var timer: DispatchSourceTimer?
    private var tick = 0
    /// Banners already handled, oldest first. Primed with what is on screen
    /// when watching starts, so old banners aren't sent as new.
    private var seen: [String] = []
    private var seenSet: Set<String> = []
    private var watchingBanners = false
    private var badges: [HostBadge] = []
    private var bundleIdentifiers: [URL: String] = [:]
    private var icons: [String: Data] = [:]
    /// AnyRemote's banners and badges (any copy's, and its Dock stand-ins')
    /// would echo a viewer's copies back to it when a Mac controls itself.
    private let ownName = NSRunningApplication.current.localizedName ?? ""
    private let ownBundlePrefix = "com.localhost-copilot.anyremote"

    func subscribe(_ session: HostSession, _ subscription: NoticeSubscription) {
        queue.async { [self] in
            let id = session.sessionID
            let wantedBadges = subscribers[id]?.subscription.badges ?? false
            if subscription.isEmpty {
                subscribers[id] = nil
            } else {
                var subscriber = subscribers[id] ?? Subscriber(session: session, subscription: subscription)
                subscriber.subscription = subscription
                subscribers[id] = subscriber
            }
            log.notice("viewer \(id) notices: notifications \(subscription.notifications), badges \(subscription.badges)")
            update()
            // A new subscriber gets the badges shown now.
            if subscription.badges, !wantedBadges {
                if badges.isEmpty { badges = readBadges() }
                session.connection.send(.badges(badges))
            }
        }
    }

    func remove(_ session: HostSession) {
        queue.async { [self] in
            subscribers[session.sessionID] = nil
            update()
        }
    }

    /// Opens the banner as a click on it would, if it is still shown.
    func open(id: String) {
        queue.async {
            let opened = NotificationBannerReader.open(id: id)
            log.notice("open notification: banner \(opened ? "pressed" : "gone", privacy: .public)")
        }
    }

    // MARK: Polling

    private var wantsNotifications: Bool { subscribers.values.contains { $0.subscription.notifications } }
    private var wantsBadges: Bool { subscribers.values.contains { $0.subscription.badges } }

    private func update() {
        subscribers = subscribers.filter { $0.value.session != nil }
        if wantsNotifications, !watchingBanners {
            watchingBanners = true
            for banner in NotificationBannerReader.read() { markSeen(banner.id) }
        } else if !wantsNotifications {
            watchingBanners = false
        }
        if !wantsBadges { badges = [] }
        if subscribers.isEmpty {
            timer?.cancel()
            timer = nil
            seen = []
            seenSet = []
        } else if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    private func poll() {
        tick += 1
        if watchingBanners { pollBanners() }
        if wantsBadges, tick % 4 == 0 { pollBadges() }
    }

    private func pollBanners() {
        let fresh = NotificationBannerReader.read().filter { !seenSet.contains($0.id) }
        for banner in fresh {
            markSeen(banner.id)
            guard ownName.isEmpty || !banner.applicationName.contains(ownName) else { continue }
            let application = application(named: banner.applicationName)
            guard !(application?.bundleIdentifier?.hasPrefix(ownBundlePrefix) ?? false) else { continue }
            // macOS asking whether an app may notify ("“Mail” Notifications") is
            // a question for the host, titled with what reads as the app's name.
            guard application != nil || banner.applicationName != banner.title else { continue }
            log.notice("notification from \(banner.applicationName, privacy: .public)")
            let notification = HostNotification(
                id: banner.id, applicationName: banner.applicationName,
                bundleIdentifier: application?.bundleIdentifier, applicationPath: application?.path,
                title: banner.title, subtitle: banner.subtitle, body: banner.body)
            for (id, subscriber) in subscribers where subscriber.subscription.notifications {
                guard let session = subscriber.session else { continue }
                var message = notification
                if let path = application?.path, !subscriber.sentIcons.contains(path) {
                    message.icon = icon(path: path)
                    subscribers[id]?.sentIcons.insert(path)
                }
                session.connection.send(.hostNotification(message))
            }
        }
    }

    private func pollBadges() {
        let current = readBadges()
        guard current != badges else { return }
        badges = current
        for subscriber in subscribers.values where subscriber.subscription.badges {
            subscriber.session?.connection.send(.badges(current))
        }
    }

    private func readBadges() -> [HostBadge] {
        DockBadgeReader.read().compactMap { badge in
            let bundleIdentifier = badge.url.flatMap(bundleIdentifier(at:))
            guard !(bundleIdentifier?.hasPrefix(ownBundlePrefix) ?? false) else { return nil }
            return HostBadge(applicationName: badge.applicationName, bundleIdentifier: bundleIdentifier,
                             label: badge.label)
        }
    }

    private func markSeen(_ id: String) {
        guard seenSet.insert(id).inserted else { return }
        seen.append(id)
        if seen.count > 1000 { seenSet.remove(seen.removeFirst()) }
    }

    // MARK: Apps

    /// The app a banner names: a running app of that name, or one installed
    /// under it (a script's notifications come from Script Editor).
    private func application(named name: String) -> (bundleIdentifier: String?, path: String)? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
           let url = running.bundleURL {
            return (running.bundleIdentifier, url.path)
        }
        let fileManager = FileManager.default
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).app")
            if fileManager.fileExists(atPath: url.path) { return (bundleIdentifier(at: url), url.path) }
        }
        return nil
    }

    private func bundleIdentifier(at url: URL) -> String? {
        if let known = bundleIdentifiers[url] { return known }
        let identifier = Bundle(url: url)?.bundleIdentifier
        if let identifier { bundleIdentifiers[url] = identifier }
        return identifier
    }

    private func icon(path: String) -> Data? {
        if let cached = icons[path] { return cached }
        // Drawing the icon is main-thread work; the main thread never waits on this queue.
        let icon = DispatchQueue.main.sync { MainActor.assumeIsolated { HostApplications.icon(path: path) } }
        icons[path] = icon
        return icon
    }
}
