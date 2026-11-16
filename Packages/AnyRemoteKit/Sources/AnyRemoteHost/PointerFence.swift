import CoreGraphics
import Foundation
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "PointerFence")

/// Keeps this Mac's own pointer off the virtual displays for remote windows.
/// They only touch the others at a corner, but the pointer could still slip
/// through one, onto a screen nobody here can see. Pointer moves
/// that land on the display are turned back, except the ones this process
/// posts for the viewer, which are how its remote windows get used.
///
/// The tap sees every pointer move on this Mac, so it runs on a thread of
/// its own: a busy main thread would make the whole pointer stutter.
public final class PointerFence: @unchecked Sendable {
    private let lock = NSLock()
    private var fenced: Set<CGDirectDisplayID> = []
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    /// The displays guarded.
    public var displayIDs: Set<CGDirectDisplayID> {
        get { lock.lock(); defer { lock.unlock() }; return fenced }
        set { lock.lock(); fenced = newValue; lock.unlock() }
    }

    /// Starts the tap, guarding nothing yet; nil if it can't be made
    /// (without Accessibility access).
    public init?() {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let fence = Unmanaged<PointerFence>.fromOpaque(context).takeUnretainedValue()
            return fence.handle(type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log.error("pointer fence: event tap unavailable")
            return nil
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            self?.runLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "anyremote.pointer-fence"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        log.info("pointer fence started")
    }

    deinit { stop() }

    /// Removes the tap and ends its thread.
    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let fenced = displayIDs
        let location = event.location
        guard fenced.contains(where: { CGDisplayBounds($0).contains(location) }),
              event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else {
            return Unmanaged.passUnretained(event)
        }
        // Back to the nearest point of the displays this Mac's user sees.
        let target = Self.nearestPoint(to: location, outside: fenced)
        CGWarpMouseCursorPosition(target)
        event.location = target
        return Unmanaged.passUnretained(event)
    }

    static func nearestPoint(to point: CGPoint, outside excluded: Set<CGDirectDisplayID>) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let candidates = ids.prefix(Int(count)).filter { !excluded.contains($0) }.map { bounds -> CGPoint in
            let rect = CGDisplayBounds(bounds)
            return CGPoint(x: min(max(point.x, rect.minX), rect.maxX - 1), y: min(max(point.y, rect.minY), rect.maxY - 1))
        }
        return candidates.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }
            ?? CGPoint(x: CGDisplayBounds(CGMainDisplayID()).midX, y: CGDisplayBounds(CGMainDisplayID()).midY)
    }
}
