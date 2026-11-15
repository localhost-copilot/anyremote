import AnyRemoteMedia
import AnyRemoteWire
import AppKit

/// Receives input from a surface view and maps it to the opened host window.
@MainActor
protocol RemoteInputSink: AnyObject {
    /// Host-window points (top-left origin) for a screen point (Cocoa coordinates).
    func hostPoint(forScreenPoint point: NSPoint) -> CGPoint
    func sendInput(_ event: InputEvent)
    func pressBegan()
    func pressEnded()
    var remoteCursor: NSCursor? { get }
}

/// A view showing one host surface and forwarding the mouse to the host.
///
/// Keys are forwarded application-wide by `KeyForwarder`, so they reach the
/// host even while a child window (menu) has the mouse.
final class RemoteSurfaceView: NSView {
    let frameLayer = VideoFrameLayer()
    weak var sink: (any RemoteInputSink)?
    private var pressedButtons: UInt32 = 0
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { frameLayer }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        frameLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInActiveApp, .inVisibleRect,
                                                          .cursorUpdate, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Cursor

    override func cursorUpdate(with event: NSEvent) {
        (sink?.remoteCursor ?? .arrow).set()
    }

    func refreshCursor() {
        guard let window, window.isVisible else { return }
        let location = window.mouseLocationOutsideOfEventStream
        if bounds.contains(convert(location, from: nil)) { (sink?.remoteCursor ?? .arrow).set() }
    }

    // MARK: Mouse

    private func point(_ event: NSEvent) -> CGPoint {
        let screen = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        return sink?.hostPoint(forScreenPoint: screen) ?? .zero
    }

    private static func modifiers(_ event: NSEvent) -> UInt64 {
        event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
    }

    private func down(_ event: NSEvent, _ button: InputEvent.MouseButton) {
        if pressedButtons == 0 { sink?.pressBegan() }
        pressedButtons |= 1 << UInt32(min(event.buttonNumber, 31))
        sink?.sendInput(.mouseDown(point: point(event), button: button, buttonNumber: event.buttonNumber,
                                   clickCount: event.clickCount, modifiers: Self.modifiers(event)))
    }

    private func up(_ event: NSEvent, _ button: InputEvent.MouseButton) {
        sink?.sendInput(.mouseUp(point: point(event), button: button, buttonNumber: event.buttonNumber,
                                 clickCount: event.clickCount, modifiers: Self.modifiers(event)))
        pressedButtons &= ~(1 << UInt32(min(event.buttonNumber, 31)))
        if pressedButtons == 0 { sink?.pressEnded() }
    }

    private func moved(_ event: NSEvent) {
        sink?.sendInput(.mouseMove(point: point(event), pressedButtons: pressedButtons,
                                   modifiers: Self.modifiers(event)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        down(event, .left)
    }
    override func mouseUp(with event: NSEvent) { up(event, .left) }
    override func rightMouseDown(with event: NSEvent) { down(event, .right) }
    override func rightMouseUp(with event: NSEvent) { up(event, .right) }
    override func otherMouseDown(with event: NSEvent) { down(event, .other) }
    override func otherMouseUp(with event: NSEvent) { up(event, .other) }
    override func mouseMoved(with event: NSEvent) { moved(event) }
    override func mouseDragged(with event: NSEvent) { moved(event) }
    override func rightMouseDragged(with event: NSEvent) { moved(event) }
    override func otherMouseDragged(with event: NSEvent) { moved(event) }
    // Keep context menus and gestures from being handled locally.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func scrollWheel(with event: NSEvent) {
        sink?.sendInput(.scroll(point: point(event), deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                precise: event.hasPreciseScrollingDeltas, phase: UInt32(event.phase.rawValue),
                                momentumPhase: UInt32(event.momentumPhase.rawValue),
                                modifiers: Self.modifiers(event)))
    }
}

/// Forwards every key event to the host while a mirror window is key.
///
/// A local monitor sees keys before menus and input methods, so Command
/// shortcuts, Tab and the host's own input methods all behave as on the host.
/// ⌃⌥⌘-shortcuts stay local (close mirror, statistics, library).
@MainActor
final class KeyForwarder {
    private var monitor: Any?
    static let localModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

    func install(target: @escaping @MainActor () -> MirrorWindowController?) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            guard let mirror = target() else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.type != .flagsChanged, flags.isSuperset(of: Self.localModifiers) { return event }
            let modifiers = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
            switch event.type {
            case .keyDown:
                mirror.sendInput(.key(keyCode: event.keyCode, down: true, isRepeat: event.isARepeat,
                                      modifiers: modifiers))
            case .keyUp:
                mirror.sendInput(.key(keyCode: event.keyCode, down: false, isRepeat: false, modifiers: modifiers))
            case .flagsChanged:
                mirror.sendInput(.flagsChanged(keyCode: event.keyCode, modifiers: modifiers))
                return event
            default:
                return event
            }
            return nil
        }
    }
}
