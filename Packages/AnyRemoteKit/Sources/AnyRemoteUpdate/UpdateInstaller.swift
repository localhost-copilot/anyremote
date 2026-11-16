import Foundation

/// Replaces the app with a staged update once it has quit.
///
/// A running app's bundle shouldn't change under it, so a small shell script
/// started here waits for this process to exit, swaps the bundles (keeping
/// the old one until the new one is in place) and optionally opens the new
/// one. The script outlives the app: a GUI app's children aren't signalled
/// when it quits.
public enum UpdateInstaller {
    /// Whether the app at `url` can be replaced in place by this user.
    public static func canReplace(_ url: URL) -> Bool {
        // A quarantined download run from where it was unpacked is run from a
        // read-only random path (App Translocation).
        guard !url.path.contains("/AppTranslocation/") else { return false }
        let parent = url.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parent) && FileManager.default.isWritableFile(atPath: url.path)
    }

    /// Starts the script; the caller then quits. `environment` is passed to
    /// the relaunched app (development launches keep their settings home).
    public static func start(_ update: StagedUpdate, replacing app: URL, waitingFor pid: Int32, relaunch: Bool,
                             environment: [String: String] = [:]) throws {
        let script = update.appURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("install.sh")
        try self.script.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        var arguments = [script.path, String(pid), update.appURL.path, app.path, relaunch ? "1" : "0"]
        arguments += environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateError.install(error.localizedDescription) }
    }

    /// `install.sh <pid> <new app> <installed app> <relaunch 0|1> [VAR=value…]`
    static let script = #"""
    #!/bin/zsh
    # Written by AnyRemote's updater. Waits for AnyRemote to quit, then puts
    # the new version in place of the old one.
    set -u
    pid=$1 new=$2 app=$3 relaunch=$4
    shift 4
    for _ in {1..600}; do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
    kill -0 $pid 2>/dev/null && exit 1
    old="$app.previous-$$"
    if mv "$app" "$old" && mv "$new" "$app"; then
        rm -rf "$old"
        xattr -dr com.apple.quarantine "$app" 2>/dev/null
    else
        [[ -e "$old" && ! -e "$app" ]] && mv "$old" "$app"
    fi
    if [[ $relaunch == 1 ]]; then
        env_args=()
        for assignment in "$@"; do env_args+=(--env "$assignment"); done
        /usr/bin/open -n "${env_args[@]}" "$app"
    fi
    """#
}
