import Foundation
import OSLog
import UserNotifications

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Viewer")

/// Tells the person at this Mac that a Mac which paired with it can now be
/// controlled from here, so the new entry in My Macs isn't a surprise.
enum PeerPairingNotice {
    static func show(name: String) {
        // Development runs with their own settings directory stay quiet.
        guard ProcessInfo.processInfo.environment["ANYREMOTE_HOME"] == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "“\(name)” paired with this Mac")
            content.body = String(localized: "You can control “\(name)” from here too. It’s now in My Macs.")
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "peer-pairing-\(name)", content: content, trigger: nil)) { error in
                if let error { log.error("notification failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }
}
