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
        }
    }

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
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Self.scrollPhase(phase))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Self.momentumPhase(momentumPhase))
        event.post(tap: .cghidEventTap)
    }
}
