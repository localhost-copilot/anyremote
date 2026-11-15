import Foundation

/// The viewer's "Share Clipboard" setting; connections follow it live.
enum ClipboardSharing {
    static let changed = Notification.Name("AnyRemoteClipboardSharingChanged")
    private static let key = "SharesClipboard"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}
