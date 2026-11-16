import AnyRemoteWire
import CoreGraphics
import Foundation
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "VirtualDisplay")

/// The virtual displays remote windows live on while a viewer is in control:
/// one per viewer screen its windows are on, that screen's size.
///
/// On a display of its own a window can be as large as the viewer's screen
/// its mirror is on, whatever the size of this Mac's screens; going full
/// screen takes a Space of that display only, so this Mac's own windows stay
/// put (and the viewer's windows on its other screens keep showing); and
/// this Mac's user keeps their screens. Each display touches the others only
/// at a corner, chained one after another, and `PointerFence` keeps this
/// Mac's own pointer off them.
///
/// macOS mirrors every new display with this Mac's screen at first (its
/// windows shift for a moment, whatever the display's identity), so a
/// display is made only once a window needs it, and they all stay until the
/// viewer leaves.
///
/// Confined to the host service's queue, except `displayIDs`.
final class RemoteDisplays: @unchecked Sendable {
    private struct Entry {
        /// The viewer screen (nil: no screen known, or a fixed size).
        let screenID: UInt32?
        let display: VirtualDisplay
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var fence: PointerFence?
    /// The visible frame (global top-left points) of the display containing a point.
    private let visibleFrame: (CGPoint) -> CGRect?

    /// The largest a display can become without being made anew.
    static let maximumSize = CGSize(width: 3840, height: 2400)

    init(visibleFrame: @escaping (CGPoint) -> CGRect?) {
        self.visibleFrame = visibleFrame
    }

    /// Every display made for remote windows. Any thread.
    var displayIDs: Set<CGDirectDisplayID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(entries.map(\.display.displayID))
    }

    var isEmpty: Bool { displayIDs.isEmpty }

    /// The display for windows shown on `screen` (nil: one shared display of
    /// `fallbackSize`), made if needed, and the frame a window there may
    /// take. Nil if no display can be made.
    func target(for screen: ViewerScreen?, fallbackSize: CGSize) -> (displayID: CGDirectDisplayID, frame: CGRect)? {
        let size = (screen?.size).map { CGSize(width: $0.width.rounded(), height: $0.height.rounded()) } ?? fallbackSize
        lock.lock()
        // No screen said: any display there is will do.
        let existing = screen == nil ? entries.first : entries.first { $0.screenID == screen?.id }
        lock.unlock()
        let display: VirtualDisplay
        if let existing {
            display = existing.display
            // The viewer's screen changed resolution.
            if display.pointSize != size, size.width <= Self.maximumSize.width, size.height <= Self.maximumSize.height {
                display.resize(to: size)
            }
        } else {
            guard let made = make(size: size) else { return nil }
            display = made
            lock.lock()
            entries.append(Entry(screenID: screen?.id, display: made))
            lock.unlock()
            log.notice("made virtual display \(made.displayID) of \(Int(size.width))x\(Int(size.height)) for viewer screen \(screen.map { String($0.id) } ?? "-", privacy: .public)")
            place(made)
            // The window server needs a moment to settle the new arrangement.
            usleep(300_000)
            if fence == nil { fence = PointerFence() }
            fence?.displayIDs = displayIDs
        }
        return (display.displayID, frame(of: display))
    }

    /// The frame a window on `displayID` may take, if it is one of these.
    func frame(of displayID: CGDirectDisplayID) -> CGRect? {
        lock.lock()
        let display = entries.first { $0.display.displayID == displayID }?.display
        lock.unlock()
        return display.map(frame(of:))
    }

    private func frame(of display: VirtualDisplay) -> CGRect {
        visibleFrame(CGPoint(x: display.bounds.midX, y: display.bounds.midY)) ?? display.bounds
    }

    private func make(size: CGSize) -> VirtualDisplay? {
        // Displays with one product ID can't exist at once: one per display
        // here, and another AnyRemote host on this Mac (during development)
        // takes the next free ones.
        for productID: UInt32 in 1...12 {
            lock.lock()
            let taken = entries.contains { $0.display.productID == productID }
            lock.unlock()
            if taken { continue }
            if let display = VirtualDisplay(pointSize: size, maximumPointSize: Self.maximumSize,
                                            name: "AnyRemote", productID: productID) {
                return display
            }
        }
        return nil
    }

    /// Extended, at 2x, at the corner of this Mac's screens and the displays
    /// made before it.
    private func place(_ display: VirtualDisplay) {
        display.makeExtended()
        display.useHiDPIMode()
        display.placeAtCorner(of: anchors(for: display))
    }

    /// This Mac's own displays and the remote displays made before `display`.
    private func anchors(for display: VirtualDisplay) -> [CGDirectDisplayID] {
        lock.lock()
        let ours = entries.map(\.display.displayID)
        lock.unlock()
        let earlier = ours.prefix { $0 != display.displayID }
        return VirtualDisplay.onlineDisplays().filter { !ours.contains($0) } + earlier
    }

    /// After macOS rearranged the displays: puts back each one it mirrored
    /// or moved. Returns the frames windows may take on the displays put
    /// back, for the windows that were moved off them.
    func restoreArrangement() -> [CGDirectDisplayID: CGRect] {
        lock.lock()
        let displays = entries.map(\.display)
        lock.unlock()
        var restored: [CGDirectDisplayID: CGRect] = [:]
        for display in displays where CGDisplayIsOnline(display.displayID) != 0 {
            let mirrored = CGDisplayIsInMirrorSet(display.displayID) != 0
            let corner = VirtualDisplay.corner(of: anchors(for: display))
            guard mirrored || display.bounds.origin != corner else { continue }
            log.notice("virtual display \(display.displayID) was \(mirrored ? "mirrored" : "moved", privacy: .public); putting it back")
            place(display)
            usleep(300_000)
            restored[display.displayID] = frame(of: display)
        }
        return restored
    }

    /// Removes every display (windows must have left them).
    func removeAll() {
        lock.lock()
        let count = entries.count
        entries.removeAll()
        let fence = fence
        self.fence = nil
        lock.unlock()
        fence?.stop()
        if count > 0 { log.info("removed \(count) virtual display(s)") }
    }
}
