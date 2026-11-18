import AppKit
import Foundation

/// Which app launched another. LaunchServices notes the app that asked for a
/// launch: Finder for a double-clicked app or document, the Dock, an app
/// opening another through NSWorkspace (a mail link, "Open With"). The
/// process tree can't tell: every app is a child of launchd. Launches from
/// the command line (`open`) and through Apple events note no launcher.
///
/// The lookup is private LaunchServices API, as `lsappinfo` uses it.
enum LaunchOrigin {
    private typealias CreateASN = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

    private static let functions: (create: CreateASN, copy: CopyItem)? = {
        let any = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let create = dlsym(any, "_LSASNCreateWithPid"),
              let copy = dlsym(any, "_LSCopyApplicationInformationItem") else { return nil }
        return (unsafeBitCast(create, to: CreateASN.self), unsafeBitCast(copy, to: CopyItem.self))
    }()

    /// kLSDefaultSessionID.
    private static let session: Int32 = -2

    /// The process that launched this app, while it still runs; nil if none
    /// was noted or it has quit.
    static func launcherPID(of pid: pid_t) -> pid_t? {
        guard let functions, let asn = functions.create(nil, pid)?.takeRetainedValue(),
              let parent = functions.copy(session, asn, "LSParentASN" as CFString)?.takeRetainedValue(),
              let launcher = functions.copy(session, parent, "pid" as CFString)?.takeRetainedValue() as? NSNumber
        else { return nil }
        return launcher.int32Value
    }
}
