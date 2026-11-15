import AppKit
import Foundation

/// The viewer's "Use This Mac's Microphone on Other Macs" setting;
/// connections follow it live.
enum MicrophoneSharing {
    static let changed = Notification.Name("AnyRemoteMicrophoneSharingChanged")
    private static let key = "SendsMicrophone"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Asked once per launch: an app on the other Mac wants to hear you, but
    /// this Mac hasn't allowed AnyRemote its microphone.
    @MainActor private static var explainedDenial = false

    @MainActor
    static func explainDenial(hostName: String) {
        guard !explainedDenial else { return }
        explainedDenial = true
        let alert = NSAlert()
        alert.messageText = String(localized: "AnyRemote Can’t Use This Mac’s Microphone")
        alert.informativeText = String(localized: "An app on “\(hostName)” is recording. To let it hear you, allow AnyRemote in Privacy & Security › Microphone.")
        alert.addButton(withTitle: String(localized: "Open Privacy Settings"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        DispatchQueue.main.async {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
}
