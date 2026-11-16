import AnyRemoteWire
import AppKit
import CoreGraphics
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Input")

/// Posts viewer input as HID events at the host window's location.
///
/// Points arrive relative to the opened window's top-left corner. While any
/// button is held, the window origin used for mapping is frozen at the press,
/// so dragging the host window by its title bar moves it with the pointer
/// instead of chasing its own movement. Not thread-safe: use from one queue.
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var pressedButtons: UInt32 = 0
    private var frozenOrigin: CGPoint?
    private var lastClickCount = 1

    /// Accessibility covers posting events. Its check updates as soon as the
    /// switch is turned on; the PostEvent check only after a relaunch.
    static var isAllowed: Bool { CGPreflightPostEventAccess() || AXIsProcessTrusted() }

    static func requestAccess() { _ = CGRequestPostEventAccess() }

    var isPressed: Bool { pressedButtons != 0 }

    /// - Parameter origin: current top-left of the window, global points.
    func post(_ event: InputEvent, windowOrigin origin: CGPoint) {
        let base = frozenOrigin ?? origin
        func global(_ point: CGPoint) -> CGPoint { CGPoint(x: base.x + point.x, y: base.y + point.y) }

        switch event {
        case let .mouseMove(point, pressed, modifiers):
            let location = global(point)
            let (type, button) = Self.dragType(pressed: pressed & pressedButtons)
            postMouse(type, at: location, button: button, modifiers: modifiers, clickCount: lastClickCount)

        case let .mouseDown(point, button, number, clickCount, modifiers):
            if pressedButtons == 0 { frozenOrigin = origin }
            let location = CGPoint(x: (frozenOrigin ?? origin).x + point.x, y: (frozenOrigin ?? origin).y + point.y)
            pressedButtons |= 1 << UInt32(min(number, 31))
            lastClickCount = clickCount
            let type: CGEventType = switch button {
            case .left: .leftMouseDown
            case .right: .rightMouseDown
            case .other: .otherMouseDown
            }
            postMouse(type, at: location, button: CGMouseButton(rawValue: UInt32(number)) ?? .left,
                      modifiers: modifiers, clickCount: clickCount)

        case let .mouseUp(point, button, number, clickCount, modifiers):
            let location = global(point)
            pressedButtons &= ~(1 << UInt32(min(number, 31)))
            let type: CGEventType = switch button {
            case .left: .leftMouseUp
            case .right: .rightMouseUp
            case .other: .otherMouseUp
            }
            postMouse(type, at: location, button: CGMouseButton(rawValue: UInt32(number)) ?? .left,
                      modifiers: modifiers, clickCount: clickCount)
            if pressedButtons == 0 { frozenOrigin = nil }

        case let .scroll(point, deltaX, deltaY, precise, phase, momentumPhase, modifiers):
            postScroll(at: global(point), deltaX: deltaX, deltaY: deltaY, precise: precise,
                       phase: phase, momentumPhase: momentumPhase, modifiers: modifiers)

        case let .key(keyCode, down, isRepeat, modifiers):
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
            event.flags = CGEventFlags(rawValue: modifiers)
            if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            event.post(tap: .cghidEventTap)

        case let .flagsChanged(keyCode, modifiers):
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else { return }
            event.type = .flagsChanged
            event.flags = CGEventFlags(rawValue: modifiers)
            event.post(tap: .cghidEventTap)

        case let .text(text):
            postText(text)

        case let .gesture(point, kind, phase, value, modifiers):
            postGesture(kind, at: global(point), phase: Self.scrollPhase(phase), value: value, modifiers: modifiers)
        }
    }

    // MARK: Gestures

    /// Gesture events have no public API. The window server's own trackpad
    /// events are CGEvents of type 29 (`NSEventTypeGesture`) whose private
    /// fields name the gesture (field 110: the IOHIDEventType: 5 rotation,
    /// 6 scroll, 8 zoom, 22 smart zoom), its amount (113 zoom, 114 rotation,
    /// 118/119 scroll) and phase (132, a CGScrollPhase); AppKit turns them
    /// into magnify, rotate and smartMagnify events. Checked on macOS 27.
    private enum GestureField {
        static let hidType = field(110)
        static let zoom = field(113)
        static let rotation = field(114)
        static let scrollX = field(118)
        static let scrollY = field(119)
        static let phase = field(132)
        static func field(_ value: UInt32) -> CGEventField { unsafeBitCast(value, to: CGEventField.self) }
    }

    private static let gestureType = unsafeBitCast(UInt32(29), to: CGEventType.self)

    private func postGesture(_ kind: InputEvent.GestureKind, at location: CGPoint, phase: Int64, value: Double,
                             modifiers: UInt64) {
        guard let event = CGEvent(source: source) else { return }
        event.type = Self.gestureType
        event.location = location
        event.flags = CGEventFlags(rawValue: modifiers)
        switch kind {
        case .magnify:
            event.setIntegerValueField(GestureField.hidType, value: 8)
            event.setDoubleValueField(GestureField.zoom, value: value)
        case .rotate:
            event.setIntegerValueField(GestureField.hidType, value: 5)
            event.setDoubleValueField(GestureField.rotation, value: value)
        case .smartMagnify:
            event.setIntegerValueField(GestureField.hidType, value: 22)
        }
        event.setIntegerValueField(GestureField.phase, value: phase)
        event.post(tap: .cghidEventTap)
    }

    /// A trackpad scroll comes with a scroll gesture event; swipe tracking
    /// (two-finger swipes between pages, `trackSwipeEvent`) follows those,
    /// not the scroll events, and never moves without them.
    private func postScrollGesture(at location: CGPoint, deltaX: Double, deltaY: Double, phase: Int64) {
        guard let event = CGEvent(source: source) else { return }
        event.type = Self.gestureType
        event.location = location
        event.setIntegerValueField(GestureField.hidType, value: 6)
        event.setDoubleValueField(GestureField.scrollX, value: deltaX)
        event.setDoubleValueField(GestureField.scrollY, value: deltaY)
        event.setIntegerValueField(GestureField.phase, value: phase)
        event.post(tap: .cghidEventTap)
    }

    /// Types text whatever the host's keyboard layout: each key event carries
    /// its characters in place of a key's. No modifiers, so a held Shift or
    /// Option on the viewer doesn't turn it into a shortcut.
    private func postText(_ text: String) {
        for chunk in Self.chunks(of: text) {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return }
                event.flags = []
                chunk.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// A key event carries at most 20 UTF-16 units (more are cut off); the
    /// text is split between characters, so no character is ever split.
    static func chunks(of text: String, maxLength: Int = 20) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > maxLength {
                chunks.append(current)
                current = []
            }
            current += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: Bridged drags

    /// The drag bridge drives the pointer itself, in global points: the
    /// viewer's own drag has taken the press over (see `HostDragBridge`).
    func pressForDrag(at location: CGPoint) {
        pressedButtons = 1
        frozenOrigin = nil
        lastClickCount = 1
        postMouse(.leftMouseDown, at: location, button: .left, modifiers: 0, clickCount: 1)
    }

    func drag(to location: CGPoint, modifiers: UInt64) {
        if modifiers != lastDragModifiers, let event = CGEvent(source: source) {
            // Option or Command pressed mid-drag changes what a drop does.
            event.type = .flagsChanged
            event.flags = CGEventFlags(rawValue: modifiers)
            event.post(tap: .cghidEventTap)
            lastDragModifiers = modifiers
        }
        postMouse(.leftMouseDragged, at: location, button: .left, modifiers: modifiers, clickCount: 1)
    }

    /// Ends the press the bridge (or the viewer's own press before it) began.
    func releaseDrag(at location: CGPoint) {
        postMouse(.leftMouseUp, at: location, button: .left, modifiers: lastDragModifiers, clickCount: 1)
        pressedButtons = 0
        frozenOrigin = nil
        if lastDragModifiers != 0, let event = CGEvent(source: source) {
            event.type = .flagsChanged
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
        lastDragModifiers = 0
    }

    /// Escape: cancels the drag under way.
    func cancelDrag() {
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    private var lastDragModifiers: UInt64 = 0

    /// Releases anything still held, e.g. when the viewer disconnects mid-drag.
    func releaseAll(windowOrigin origin: CGPoint) {
        let location = CGEvent(source: nil)?.location ?? origin
        for number in 0..<32 where pressedButtons & (1 << UInt32(number)) != 0 {
            let type: CGEventType = number == 0 ? .leftMouseUp : number == 1 ? .rightMouseUp : .otherMouseUp
            postMouse(type, at: location, button: CGMouseButton(rawValue: UInt32(number)) ?? .left,
                      modifiers: 0, clickCount: 1)
        }
        pressedButtons = 0
        frozenOrigin = nil
        if let event = CGEvent(source: source) {
            event.type = .flagsChanged
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }

    private static func dragType(pressed: UInt32) -> (CGEventType, CGMouseButton) {
        if pressed & 1 != 0 { return (.leftMouseDragged, .left) }
        if pressed & 2 != 0 { return (.rightMouseDragged, .right) }
        if pressed != 0 {
            let number = UInt32(pressed.trailingZeroBitCount)
            return (.otherMouseDragged, CGMouseButton(rawValue: number) ?? .center)
        }
        return (.mouseMoved, .left)
    }

    private func postMouse(_ type: CGEventType, at location: CGPoint, button: CGMouseButton,
                           modifiers: UInt64, clickCount: Int) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
                                  mouseButton: button) else { return }
        event.flags = CGEventFlags(rawValue: modifiers)
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        if type == .otherMouseDown || type == .otherMouseUp || type == .otherMouseDragged {
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        }
        event.post(tap: .cghidEventTap)
    }

    /// NSEvent.Phase → CGScrollPhase / CGMomentumScrollPhase.
    static func scrollPhase(_ phase: UInt32) -> Int64 {
        let phase = NSEvent.Phase(rawValue: UInt(phase))
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) { return 4 }
        if phase.contains(.cancelled) { return 8 }
        if phase.contains(.mayBegin) { return 128 }
        return 0
    }

    static func momentumPhase(_ phase: UInt32) -> Int64 {
        let phase = NSEvent.Phase(rawValue: UInt(phase))
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) || phase.contains(.cancelled) { return 3 }
        return 0
    }

    private func postScroll(at location: CGPoint, deltaX: Double, deltaY: Double, precise: Bool,
                            phase: UInt32, momentumPhase: UInt32, modifiers: UInt64) {
        // A notched wheel reports fractional line deltas; a small one must
        // still scroll a line rather than round to nothing.
        func lines(_ delta: Double) -> Int32 {
            guard !precise, delta != 0 else { return Int32(delta.rounded()) }
            return Int32(delta < 0 ? min(-1, delta.rounded()) : max(1, delta.rounded()))
        }
        let scrollPhase = Self.scrollPhase(phase)
        if precise, scrollPhase != 0 {
            postScrollGesture(at: location, deltaX: deltaX, deltaY: deltaY, phase: scrollPhase)
        }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: precise ? .pixel : .line, wheelCount: 2,
                                  wheel1: lines(deltaY), wheel2: lines(deltaX), wheel3: 0)
        else { return }
        event.location = location
        event.flags = CGEventFlags(rawValue: modifiers)
        if precise {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: deltaY)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: deltaX)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(deltaY.rounded()))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(deltaX.rounded()))
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Self.momentumPhase(momentumPhase))
        event.post(tap: .cghidEventTap)
    }
}
