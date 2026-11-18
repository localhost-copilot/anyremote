import CoreGraphics
import Foundation
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "LocalInputMonitor")

/// Tells which app this Mac's own user clicks or types in, as opposed to
/// the viewers, whose input this process posts. That app acts for this
/// Mac's user from then on (see `AppActors`): what it opens stays here, and
/// so do the windows of an app launched from this Mac's Dock or Finder.
///
/// The tap only reads the events and lets them through unchanged, on a
/// thread of its own so a busy queue never holds up this Mac's input.
final class LocalInputMonitor: @unchecked Sendable {
    static let shared = LocalInputMonitor()

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var started = false
    private var receiver: (@Sendable (pid_t) -> Void)?

    /// Called on the tap's thread with the app each click or key press of
    /// this Mac's user goes to.
    var onInput: (@Sendable (pid_t) -> Void)? {
        get { lock.withLock { receiver } }
        set { lock.withLock { receiver = newValue } }
    }

    /// Starts the tap the first time; later calls do nothing.
    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // A default tap (passing every event through) needs Accessibility
        // access, which the host has; a listen-only one would need Input
        // Monitoring as well.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, context in
            if let context {
                Unmanaged<LocalInputMonitor>.fromOpaque(context).takeUnretainedValue().handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log.error("local input monitor: event tap unavailable")
            return
        }
        self.tap = tap
        let thread = Thread { [self] in
            guard let tap = self.tap else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "anyremote.local-input"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Events this process posts carry its pid; everything else (the
        // keyboard and mouse here, other apps' synthetic events) counts as
        // this Mac's user.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
        guard let receiver = onInput, let pid = Self.target(of: event, type: type) else { return }
        receiver(pid)
    }

    /// The app the event goes to: for a click, the owner of the window
    /// under the pointer (the Dock, a window behind the frontmost app's),
    /// else the app macOS sends it to (for a key press, the frontmost app).
    private static func target(of event: CGEvent, type: CGEventType) -> pid_t? {
        if type != .keyDown {
            let windowID = CGWindowID(truncatingIfNeeded: event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
            if windowID != 0, let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
               let owner = info.first?[kCGWindowOwnerPID as String] as? NSNumber {
                return owner.int32Value
            }
        }
        let target = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
        return target > 0 ? target : nil
    }
}
