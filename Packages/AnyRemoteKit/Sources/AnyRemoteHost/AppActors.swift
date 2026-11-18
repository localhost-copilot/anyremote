import AppKit
import Darwin

/// Whom an app on this Mac is acting for, which decides where its new
/// windows go: a window opens on a viewer only when its app acts for that
/// viewer, and a window that came up on a virtual display though its app
/// doesn't is moved to this Mac's own screens.
enum AppActor: Equatable, Sendable {
    /// The viewer of this session: it clicked or typed in the app last,
    /// opened one of its windows, or the app was launched for it.
    case viewer(UInt32)
    /// This Mac's user, who clicked or typed in it last, or launched it.
    case host
}

/// Follows whom each app acts for. What an app does next is taken to be for
/// whoever acted on it last, so no time limit decides it: an app takes the
/// role of the latest input it received (the viewer's posted input, this
/// Mac's own keyboard and mouse) or, until it gets any, of the app that
/// launched it, as that app was acting when it did (a document
/// double-clicked in the viewer's Finder). An app nothing acted on and that
/// no app with a role launched (one started by `open` from a script, a login
/// item) acts for nobody, and its windows stay on this Mac.
///
/// What isn't seen: which process asks an app already running to open
/// something. macOS tells only the app itself (in the Apple event), so a
/// script opening a document in the app the viewer uses brings that window
/// to the viewer, and a link the viewer clicks opens on this Mac when this
/// Mac's user used the browser last.
///
/// Confined to the host service's queue.
final class AppActors: @unchecked Sendable {
    private var actors: [pid_t: (actor: AppActor, since: Date)] = [:]

    /// The app acts for `actor` from now on.
    func note(_ actor: AppActor, pid: pid_t) {
        guard pid > 0, pid != getpid() else { return }
        actors[pid] = (actor, Date())
        if actors.count > 512 { actors = actors.filter { kill($0.key, 0) == 0 } }
    }

    /// Whom the app acts for; nil for nobody.
    func actor(of pid: pid_t) -> AppActor? {
        if let known = actors[pid] { return known.actor }
        // LaunchServices may note the launcher only after the app's first
        // window shows, so this is looked up until there is an answer.
        guard let launcher = LaunchOrigin.launcherPID(of: pid), let role = actors[launcher],
              let launched = NSRunningApplication(processIdentifier: pid)?.launchDate,
              role.since <= launched else { return nil }
        actors[pid] = (role.actor, launched)
        return role.actor
    }
}
