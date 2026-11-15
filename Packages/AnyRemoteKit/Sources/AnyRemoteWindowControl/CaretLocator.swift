import ApplicationServices
import CoreGraphics
import Foundation

/// Finds the text insertion point of the focused text field through
/// Accessibility, so the viewer's input method can show its candidates there.
///
/// Calls can block on an unresponsive app (up to the messaging timeout), so
/// use from a queue of its own.
public final class CaretLocator: @unchecked Sendable {
    private let lock = NSLock()
    /// Apps already asked to expose their accessibility tree.
    private var enabledApps: Set<pid_t> = []

    public init() {}

    /// The caret of the focused element in `pid`'s app, or in the frontmost
    /// app when nil, in global points with a top-left origin.
    public func caretRect(pid: pid_t?) -> CGRect? {
        let application: AXUIElement
        if let pid {
            application = AXUIElementCreateApplication(pid)
        } else {
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, 0.25)
            guard let focused: AXUIElement = Self.attribute(systemWide, kAXFocusedApplicationAttribute) else { return nil }
            application = focused
        }
        var target: pid_t = 0
        guard AXUIElementGetPid(application, &target) == .success, target != OwnProcessAX.pid else { return nil }
        AXUIElementSetMessagingTimeout(application, 0.25)
        enableAccessibility(application, pid: target)

        guard let element: AXUIElement = Self.attribute(application, kAXFocusedUIElementAttribute),
              let rangeValue: AXValue = Self.attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.location >= 0 else { return nil }

        // An empty range has no bounds in many apps; then use the character
        // after the caret (its leading edge) or before it (its trailing edge).
        if let rect = Self.bounds(element, CFRange(location: range.location, length: 0)), rect.height > 0 {
            return CGRect(x: rect.minX, y: rect.minY, width: max(1, rect.width), height: rect.height)
        }
        if let rect = Self.bounds(element, CFRange(location: range.location, length: 1)), rect.height > 0 {
            return CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)
        }
        if range.location > 0, let rect = Self.bounds(element, CFRange(location: range.location - 1, length: 1)),
           rect.height > 0 {
            return CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height)
        }
        return nil
    }

    /// Chromium and Electron apps build their accessibility tree, text
    /// ranges included, only once an assistive app asks for it.
    private func enableAccessibility(_ application: AXUIElement, pid: pid_t) {
        lock.lock()
        let isNew = enabledApps.insert(pid).inserted
        lock.unlock()
        guard isNew else { return }
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == typeID(T.self) else { return nil }
        return (value as! T)
    }

    private static func typeID<T>(_ type: T.Type) -> CFTypeID {
        type == AXValue.self ? AXValueGetTypeID() : AXUIElementGetTypeID()
    }

    private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height < 1000 else { return nil }
        return rect
    }
}
