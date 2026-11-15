import Foundation

/// The viewer's "Play Sound from Other Macs" setting; connections follow it live.
enum SoundSharing {
    static let changed = Notification.Name("AnyRemoteSoundSharingChanged")
    private static let key = "PlaysRemoteSound"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}
