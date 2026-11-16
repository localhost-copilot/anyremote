import AnyRemoteWire
import AppKit
import OSLog
import UserNotifications

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Notifications")

/// Shows the notifications of apps on connected Macs in this Mac's
/// Notification Center, like Parallels does for Windows apps. A click opens
/// it on the other Mac (the conversation, the mail) and brings that app's
/// window here.
///
/// They come from AnyRemote, so each one names its app and Mac in the
/// title, "Mail (Mac mini)" as in the Dock, with the app's icon attached.
@MainActor
final class RemoteNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RemoteNotifications()
    static let changed = Notification.Name("AnyRemoteRemoteNotificationsChanged")
    private static let key = "ShowsRemoteNotifications"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// The connection for a `HostTarget.id`, to answer a click.
    var connection: (String) -> HostConnection? = { _ in nil }
    /// Development: told about every notification that arrives.
    var onArrival: ((HostNotification) -> Void)?
    /// App icons by host and app path; the host sends each one once per connection.
    private var icons: [String: Data] = [:]
    private var authorization: Task<Bool, Never>?

    /// Becomes Notification Center's delegate, so clicks reach AnyRemote and
    /// banners show while a remote window is in front too.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func show(_ notification: HostNotification, from connection: HostConnection) {
        onArrival?(notification)
        guard Self.isEnabled else { return }
        let host = connection.target.hostID ?? connection.target.id
        let iconKey = "\(host)|\(notification.applicationPath ?? notification.applicationName)"
        if let icon = notification.icon { icons[iconKey] = icon }

        let content = UNMutableNotificationContent()
        content.title = "\(notification.applicationName) (\(connection.hostName))"
        content.subtitle = [notification.title, notification.subtitle].filter { !$0.isEmpty }.joined(separator: " — ")
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = iconKey
        content.userInfo = [
            "target": connection.target.id,
            "id": notification.id,
            "application": notification.applicationName,
            "path": notification.applicationPath ?? "",
        ]
        if let icon = icons[iconKey], let attachment = Self.attachment(icon) { content.attachments = [attachment] }
        let request = UNNotificationRequest(identifier: "remote-\(notification.id)", content: content, trigger: nil)
        Task {
            guard await authorize() else { return }
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                log.error("notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Asks once per run; macOS remembers the answer.
    private func authorize() async -> Bool {
        if let authorization { return await authorization.value }
        let task = Task {
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        }
        authorization = task
        let granted = await task.value
        if !granted { log.notice("notifications not allowed on this Mac") }
        return granted
    }

    /// Whether this Mac's person turned AnyRemote's notifications off.
    static func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
        NSWorkspace.shared.open(url)
    }

    /// Notification Center moves the attachment's file into its own store.
    private static func attachment(_ png: Data) -> UNNotificationAttachment? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnyRemote-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return try UNNotificationAttachment(identifier: "icon", url: url)
        } catch {
            log.error("notification icon failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let clicked = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let target = info["target"] as? String
        let id = info["id"] as? String
        let application = info["application"] as? String
        let path = (info["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        completionHandler()
        guard clicked, let target, let id else { return }
        Task { @MainActor in self.open(id: id, application: application, path: path, target: target) }
    }

    private func open(id: String, application: String?, path: String?, target: String) {
        guard let connection = connection(target), connection.state == .connected else {
            log.notice("notification clicked, but its Mac isn't connected")
            return
        }
        // The app's windows already here come forward at once; the host
        // opens the notification and a new window it shows comes here too.
        DockProxies.bringForward(connection.openMirrors.filter { $0.stream.applicationName == application })
        connection.client.send(.openNotification(id: id, applicationPath: path))
    }
}
