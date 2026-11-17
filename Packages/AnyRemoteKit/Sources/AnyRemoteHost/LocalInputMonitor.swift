import AnyRemoteMedia
import CoreGraphics
import Foundation
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "LocalInputMonitor")

/// Notes when this Mac's own user last clicked or pressed a key, as opposed
/// to the viewers, whose input this process posts. A window that opens after
/// a click here (an app launched from this Mac's Dock, a document opened in
/// its Finder) was opened by this Mac's user and stays on this Mac, even if
/// a viewer was typing a moment before.
///
/// The tap only reads the events and lets them through unchanged, on a
/// thread of its own so a busy queue never holds up this Mac's input.
final class LocalInputMonitor: @unchecked Sendable {
    static let shared = LocalInputMonitor()

    private let lock = NSLock()
    /// The latest clicks and key presses, oldest first.
    private var recent: [UInt64] = []
    private var tap: CFMachPort?
    private var started = false

    /// When this Mac's user last clicked or pressed a key (`HostClock`
    /// nanoseconds); 0 if not since the monitor started, or without the
    /// Accessibility access a tap needs.
    var lastInputNanos: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return recent.last ?? 0
    }

    /// Whether this Mac's user clicked or pressed a key in this span (after
    /// `start`, up to and including `end`). Only the latest few are kept,
    /// which reach back further than anything asked.
    func hadInput(after start: UInt64, through end: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return recent.contains { $0 > start && $0 <= end }
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
        let now = HostClock.nowNanos()
        lock.lock()
        recent.append(now)
        if recent.count > 32 { recent.removeFirst(recent.count - 32) }
        lock.unlock()
    }
}
