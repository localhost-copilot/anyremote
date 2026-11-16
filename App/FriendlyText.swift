import Foundation

/// User-facing wording for messages that come from the wire (in English) or
/// from the system.
enum FriendlyText {
    static func message(_ raw: String) -> String {
        let table: [(String, String)] = [
            ("pairing code is not valid", String(localized: "The pairing code is wrong. Check the code shown in AnyRemote › Settings on that Mac.")),
            ("authentication failed", String(localized: "The pairing code is wrong. Check the code shown in AnyRemote › Settings on that Mac.")),
            ("being controlled by", String(localized: "That Mac is being controlled by someone else.")),
            ("Remote control is turned off", String(localized: "That Mac has turned off “Allow Other Macs to Control This Mac”.")),
            ("Remote control was turned off", String(localized: "That Mac has turned off “Allow Other Macs to Control This Mac”.")),
            ("incompatible AnyRemote version", String(localized: "The two Macs run different versions of AnyRemote. Install the same version on both.")),
            ("took over this Mac", String(localized: "Another Mac took over control.")),
            ("The host ended the session", String(localized: "The connection was ended on that Mac.")),
            ("did not respond", String(localized: "That Mac didn’t respond. Make sure it’s on, AnyRemote is running, and it’s on the same network.")),
            ("Connection refused", String(localized: "Can’t connect: AnyRemote isn’t running on that Mac, or a firewall is blocking the port.")),
            ("connection was closed", String(localized: "The connection was closed.")),
            ("already runs the latest AnyRemote", String(localized: "That Mac already runs the latest released AnyRemote.")),
            ("development build of AnyRemote", String(localized: "That Mac runs a development build of AnyRemote, which doesn’t update.")),
            ("can't replace itself", String(localized: "AnyRemote on that Mac can’t replace itself where it’s installed. Move it to the Applications folder there.")),
            ("couldn't download the update", String(localized: "That Mac couldn’t download the update. Check its internet connection.")),
            ("can't be updated from another Mac", String(localized: "That Mac’s AnyRemote can’t be updated from here. Install the new version on it by hand.")),
            ("window is no longer available", String(localized: "This window has been closed.")),
        ]
        for (needle, text) in table where raw.localizedCaseInsensitiveContains(needle) {
            if needle == "being controlled by", let range = raw.range(of: "controlled by ") {
                let holder = raw[range.upperBound...].prefix { $0 != "." }
                return String(localized: "That Mac is being controlled by “\(String(holder))”.")
            }
            if needle == "took over this Mac" {
                let holder = raw.components(separatedBy: " took over").first ?? ""
                return String(localized: "“\(holder)” took over control of this Mac.")
            }
            return text
        }
        return raw
    }

    static func isPairingFailure(_ raw: String) -> Bool {
        raw.localizedCaseInsensitiveContains("pairing code") || raw.localizedCaseInsensitiveContains("authentication failed")
    }

    static func isBusy(_ raw: String) -> Bool { raw.localizedCaseInsensitiveContains("being controlled") }
}
