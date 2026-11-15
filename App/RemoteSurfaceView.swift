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
    /// True when a left press at `point` is handled locally (title bar
    /// buttons, letterbox area) and must not reach the host.
    func beginLocalPress(at point: NSPoint) -> Bool
    func endLocalPress(at point: NSPoint)
    /// While the window is dragged locally (the host app began a window
    /// drag), mouse moves move the window and the release stays local.
    func continueLocalDrag(at point: NSPoint) -> Bool
    func finishLocalDrag() -> Bool
    /// The host's text caret on this screen, when it reported one.
    func caretScreenRect() -> NSRect?
    /// The host text's font at the caret, at this window's scale, when reported.
    func caretFont() -> NSFont?
}

extension RemoteInputSink {
    func beginLocalPress(at point: NSPoint) -> Bool { false }
    func endLocalPress(at point: NSPoint) {}
    func continueLocalDrag(at point: NSPoint) -> Bool { false }
    func finishLocalDrag() -> Bool { false }
    func caretScreenRect() -> NSRect? { nil }
    func caretFont() -> NSFont? { nil }
}

/// A view showing one host surface and forwarding the mouse to the host.
///
/// Keys are forwarded application-wide by `KeyForwarder`, so they reach the
/// host even while a child window (menu) has the mouse.
final class RemoteSurfaceView: NSView {
    let frameLayer = VideoFrameLayer()
    weak var sink: (any RemoteInputSink)?
    private var pressedButtons: UInt32 = 0
    private var localPress = false
    private var tracking: NSTrackingArea?
    private(set) lazy var composer = TextComposer(view: self)
    private var resignObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { frameLayer }
    /// This Mac's input method composes through `composer` (see `KeyForwarder`).
    override var inputContext: NSTextInputContext? { composer.context }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let window else { composer.cancel(); return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.composer.cancel() }
        }
    }
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

    private func screenPoint(_ event: NSEvent) -> NSPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // The click moves the host's caret: what was being composed goes.
        composer.cancel()
        composer.clickPoint = screenPoint(event)
        if pressedButtons == 0, sink?.beginLocalPress(at: screenPoint(event)) == true {
            localPress = true
            return
        }
        down(event, .left)
    }
    override func mouseUp(with event: NSEvent) {
        if localPress {
            localPress = false
            sink?.endLocalPress(at: screenPoint(event))
            return
        }
        if sink?.finishLocalDrag() == true {
            // The host already got its release when the local drag began.
            pressedButtons &= ~1
            if pressedButtons == 0 { sink?.pressEnded() }
            return
        }
        up(event, .left)
    }
    override func rightMouseDown(with event: NSEvent) { down(event, .right) }
    override func rightMouseUp(with event: NSEvent) { up(event, .right) }
    override func otherMouseDown(with event: NSEvent) { down(event, .other) }
    override func otherMouseUp(with event: NSEvent) { up(event, .other) }
    override func mouseMoved(with event: NSEvent) {
        // The tracking area reports moves over the window buttons too; those
        // stay local (on the host they would hover its sharing indicator).
        let point = convert(event.locationInWindow, from: nil)
        if pressedButtons == 0,
           subviews.contains(where: { $0 is WindowButtonGroup && !$0.isHidden && $0.frame.contains(point) }) { return }
        moved(event)
    }
    override func mouseDragged(with event: NSEvent) {
        if localPress || sink?.continueLocalDrag(at: screenPoint(event)) == true { return }
        moved(event)
    }
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

/// A window whose keys go to the host: a mirror or a full desktop.
@MainActor
protocol RemoteKeyTarget: AnyObject {
    func sendInput(_ event: InputEvent)
    var surface: RemoteSurfaceView { get }
    /// True when the key was handled by the local window instead.
    func handleWindowShortcut(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool
}

/// Forwards every key event to the host while a mirror or desktop window is key.
///
/// A local monitor sees keys before menus, so Command shortcuts and Tab
/// behave as on the host. While this Mac's input source is an input method
/// (and composing here is on), other keys go through it first
/// (`TextComposer`), and the host gets what it composed; otherwise the
/// host's input method gets the keys. ⌃⌥⌘-shortcuts stay local (close mirror, statistics, library).
@MainActor
final class KeyForwarder {
    private var monitor: Any?
    /// Keys handled here (input source shortcuts): their releases stay here too.
    private var localKeys: Set<UInt16> = []
    static let localModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

    func install(target: @escaping @MainActor () -> (any RemoteKeyTarget)?) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, let mirror = target() else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.type != .flagsChanged, flags.isSuperset(of: Self.localModifiers) { return event }
            // Window management shortcuts act on the local window: a minimized
            // or full-screen host window can't be shown here.
            if event.type == .keyDown, mirror.handleWindowShortcut(keyCode: event.keyCode, flags: flags) { return nil }
            let modifiers = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
            let composer = mirror.surface.composer
            switch event.type {
            case .keyDown:
                if LocalInputSource.handleSwitchShortcut(event) {
                    localKeys.insert(event.keyCode)
                    return nil
                }
                if !flags.contains(.command), TextInputPreferences.composesOnThisMac, LocalInputSource.composes {
                    if mirror.surface.window?.firstResponder !== mirror.surface {
                        mirror.surface.window?.makeFirstResponder(mirror.surface)
                    }
                    if composer.handleKeyDown(event) { return nil }
                } else {
                    // A shortcut, or a keyboard layout now: the composition is over.
                    composer.cancel()
                }
                mirror.sendInput(.key(keyCode: event.keyCode, down: true, isRepeat: event.isARepeat,
                                      modifiers: modifiers))
            case .keyUp:
                if localKeys.remove(event.keyCode) != nil || composer.handleKeyUp(event) { return nil }
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
