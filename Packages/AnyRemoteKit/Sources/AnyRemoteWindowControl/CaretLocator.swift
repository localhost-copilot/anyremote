import AnyRemoteWire
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
    /// app when nil, in global points with a top-left origin, with the font
    /// of the text around it when the app tells. With text selected on one
    /// line, the rect spans it (typing replaces it).
    public func caret(pid: pid_t?) -> (rect: CGRect, font: CaretFont?)? {
        guard let element = focusedElement(pid: pid),
              let rangeValue: AXValue = Self.attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.location >= 0 else { return nil }
        let location = range.location
        let frame = Self.frame(of: element)

        // Characters have reliable bounds; an empty range often doesn't
        // (Cocoa text reports it a line too high). The caret is the leading
        // edge of the character after it, or else the trailing edge of the
        // one before it.
        let next = Self.character(element, at: location)
        let previous = location > 0 ? Self.character(element, at: location - 1) : nil
        let rect: CGRect?
        if let next, !next.isNewline {
            rect = CGRect(x: next.bounds.minX, y: next.bounds.minY, width: 1, height: next.bounds.height)
        } else if let previous, !previous.isNewline {
            rect = CGRect(x: previous.bounds.maxX, y: previous.bounds.minY, width: 1, height: previous.bounds.height)
        } else if let empty = Self.bounds(element, CFRange(location: location, length: 0)) {
            // An empty line: below the previous line break, where there is one.
            var caret = CGRect(x: empty.minX, y: empty.minY, width: 1, height: empty.height)
            if let previous { caret.origin.y = previous.bounds.maxY }
            if let frame, caret.minY < frame.minY { caret.origin.y = frame.minY }
            rect = caret
        } else {
            rect = nil
        }
        guard var rect, rect.height > 0 else { return nil }
        // Typing replaces the selection: the caret spans it when it is on one line.
        if range.length > 0, let selected = Self.bounds(element, CFRange(location: location, length: range.length)),
           abs(selected.minY - rect.minY) < 2, abs(selected.height - rect.height) < 2, selected.maxX > rect.minX {
            rect.size.width = selected.maxX - rect.minX
        }
        let font = Self.font(element, at: next.map { _ in location } ?? max(0, location - 1))
        return (rect, font)
    }

    /// The frame of the focused element in `pid`'s app, global top-left points.
    public func focusedElementFrame(pid: pid_t) -> CGRect? {
        focusedElement(pid: pid).flatMap(Self.frame)
    }

    private func focusedElement(pid: pid_t?) -> AXUIElement? {
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
        return Self.attribute(application, kAXFocusedUIElementAttribute)
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

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func parameterized(_ element: AXUIElement, _ name: String, _ range: CFRange) -> CFTypeRef? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success
        else { return nil }
        return value
    }

    private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        guard let value = parameterized(element, kAXBoundsForRangeParameterizedAttribute, range),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0, rect.height < 1000 else { return nil }
        return rect
    }

    private struct Character {
        var bounds: CGRect
        var isNewline: Bool
    }

    private static func character(_ element: AXUIElement, at location: Int) -> Character? {
        let range = CFRange(location: location, length: 1)
        guard let text = parameterized(element, kAXStringForRangeParameterizedAttribute, range) as? String,
              !text.isEmpty, let bounds = bounds(element, range) else { return nil }
        return Character(bounds: bounds, isNewline: text.unicodeScalars.allSatisfy { CharacterSet.newlines.contains($0) })
    }

    private static func font(_ element: AXUIElement, at location: Int) -> CaretFont? {
        guard let text = parameterized(element, kAXAttributedStringForRangeParameterizedAttribute,
                                       CFRange(location: location, length: 1)) as? NSAttributedString,
              text.length > 0,
              let font = text.attribute(NSAttributedString.Key("AXFont"), at: 0,
                                        effectiveRange: nil) as? [String: Any],
              let size = (font["AXFontSize"] as? NSNumber)?.doubleValue, size > 0 else { return nil }
        return CaretFont(name: font["AXFontName"] as? String ?? "", size: size)
    }
}
