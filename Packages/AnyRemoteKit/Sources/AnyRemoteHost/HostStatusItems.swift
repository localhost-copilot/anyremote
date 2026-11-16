import AnyRemoteWindowControl
import AnyRemoteWire
import AppKit
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "StatusItems")

/// The items on the right of the host's menu bar, for viewers that show
/// them in their own menu bar: lists them with their pictures, clicks them,
/// and answers the menus they open.
///
/// Accessibility calls into an app can wait for it (one whose item opens a
/// menu waits until the call times out), so they run on this queue, never
/// on the host's.
final class HostStatusItems: @unchecked Sendable {
    private let queue = DispatchQueue(label: "anyremote.statusitems", qos: .userInitiated)

    /// The items, each with its picture, then `done` on `reply`.
    func list(reply: DispatchQueue, _ done: @escaping @Sendable ([HostStatusItem]) -> Void) {
        queue.async {
            let ownPrefix = "com.localhost-copilot.anyremote"
            let own = Set(NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier?.hasPrefix(ownPrefix) ?? false }.map(\.processIdentifier))
            let infos = StatusItemReader.list(excludingPIDs: own.union([getpid()]))
            Task {
                let images = await Self.pictures(of: infos)
                let items = infos.map { info in
                    HostStatusItem(id: info.id, applicationName: info.applicationName,
                                   bundleIdentifier: info.bundleIdentifier, title: info.title,
                                   image: images[info.id], frame: info.frame)
                }
                reply.async { done(items) }
            }
        }
    }

    /// Clicks the item, then `done` with the menu it opened (nil: none, so a
    /// window may be coming).
    func open(_ id: String, reply: DispatchQueue, _ done: @escaping @Sendable ([MenuNode]?) -> Void) {
        queue.async {
            guard StatusItemReader.press(id) else {
                log.notice("menu bar item \(id, privacy: .public) is gone")
                return reply.async { done(nil) }
            }
            // An app that showed a menu has it open by now; others may take a moment.
            var menu = StatusItemReader.openMenu(id)
            if menu == nil {
                Thread.sleep(forTimeInterval: 0.15)
                menu = StatusItemReader.openMenu(id)
            }
            log.notice("menu bar item \(id, privacy: .public) opened \(menu == nil ? "no menu" : "a menu", privacy: .public)")
            reply.async { done(menu) }
        }
    }

    func finishMenu(_ id: String, path: [Int]?) {
        queue.async { StatusItemReader.finishMenu(id, path: path) }
    }

    /// Clicks the item again, which closes what it opened.
    func toggle(_ id: String) {
        queue.async { _ = StatusItemReader.press(id) }
    }

    // MARK: Pictures

    /// Each item's app icon, drawn once per app.
    private static func pictures(of infos: [StatusItemInfo]) async -> [String: Data] {
        await MainActor.run {
            var icons: [pid_t: Data] = [:]
            var result: [String: Data] = [:]
            for info in infos {
                if icons[info.pid] == nil,
                   let path = NSRunningApplication(processIdentifier: info.pid)?.bundleURL?.path {
                    icons[info.pid] = HostApplications.icon(path: path)
                }
                result[info.id] = icons[info.pid]
            }
            return result
        }
    }
}
