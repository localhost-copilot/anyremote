import AnyRemoteHost
import AppKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Microphone")

/// Installs, updates and removes the AnyRemote Microphone driver, which lets
/// apps on this Mac record from a viewer's microphone.
///
/// macOS loads audio drivers only from /Library/Audio/Plug-Ins/HAL, which
/// takes an administrator, and only when Core Audio starts, so installing
/// restarts it: sound on this Mac pauses for a moment.
@MainActor
enum MicrophoneDriverInstaller {
    enum Status: Equatable {
        case notInstalled
        case installed
        /// An older driver than the one this app carries.
        case outdated
    }

    private static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/AnyRemote Microphone.driver")

    private static var bundledURL: URL? {
        Bundle.main.url(forResource: "AnyRemote Microphone", withExtension: "driver")
    }

    static var status: Status {
        guard FileManager.default.fileExists(atPath: installedURL.path) else { return .notInstalled }
        guard let bundledURL, version(at: bundledURL) != version(at: installedURL) else { return .installed }
        return .outdated
    }

    private static func version(at url: URL) -> String? {
        // Read directly: Bundle caches by path, and the installed copy changes under it.
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleVersion"] as? String
    }

    /// Asks for an administrator password, then installs (or updates) the driver.
    static func install(service: HostService) async -> Bool {
        guard let bundledURL else {
            showFailure(String(localized: "This copy of AnyRemote doesn’t include the AnyRemote Microphone."))
            return false
        }
        let destination = shellQuoted(installedURL.path)
        let command = "/bin/mkdir -p /Library/Audio/Plug-Ins/HAL"
            + " && /bin/rm -rf \(destination)"
            + " && /usr/bin/ditto \(shellQuoted(bundledURL.path)) \(destination)"
            + " && /usr/sbin/chown -R root:wheel \(destination)"
            + " && /usr/bin/killall coreaudiod"
        guard runAsAdministrator(command) else { return false }
        // Core Audio restarts and loads the driver within a few seconds.
        await waitUntil { HostService.microphoneInstalled }
        service.microphoneDriverChanged()
        log.notice("AnyRemote Microphone installed (\(HostService.microphoneInstalled ? "loaded" : "not loaded yet", privacy: .public))")
        return true
    }

    static func remove(service: HostService) async -> Bool {
        let command = "/bin/rm -rf \(shellQuoted(installedURL.path)) && /usr/bin/killall coreaudiod"
        guard runAsAdministrator(command) else { return false }
        await waitUntil { !HostService.microphoneInstalled }
        service.microphoneDriverChanged()
        log.notice("AnyRemote Microphone removed")
        return true
    }

    /// Up to 10 s, while Core Audio restarts.
    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<40 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Runs `command` as root after macOS's administrator prompt. False if
    /// the person cancelled or it failed (the failure is shown).
    private static func runAsAdministrator(_ command: String) -> Bool {
        let source = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return true }
        // -128: the person cancelled the password prompt.
        if (error[NSAppleScript.errorNumber] as? Int) != -128 {
            showFailure(error[NSAppleScript.errorMessage] as? String ?? String(localized: "The installation failed."))
        }
        return false
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "The AnyRemote Microphone Couldn’t Be Changed")
        alert.informativeText = message
        alert.runModal()
    }
}
