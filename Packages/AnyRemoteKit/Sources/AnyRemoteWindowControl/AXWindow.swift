import ApplicationServices
import CoreGraphics
import Foundation

// Private but long-stable HIServices SPI mapping an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

public enum AccessibilityPermission {
    public static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt if the process is not yet trusted.
    @discardableResult
    public static func request() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

/// Accessibility calls into our own process are served in-process by AppKit
/// on the calling thread, which must then be the main thread. That happens
/// when this Mac mirrors its own windows (development loopback).
enum OwnProcessAX {
    static let pid = getpid()

    static func perform<T>(for target: pid_t, _ body: () -> T) -> T {
        guard target == pid, !Thread.isMainThread else { return body() }
        return DispatchQueue.main.sync(execute: body)
    }
}

public enum AXWindowError: Error, Equatable {
    case notFound
    case failed(Int32)
}

/// Geometry control of one host window through Accessibility.
///
/// Sizes and positions are in global points with a top-left origin, matching
/// `SCWindow.frame` and the window's captured content (title bar included).
public final class AXWindow: @unchecked Sendable {
    public let pid: pid_t
    public let windowID: CGWindowID
    let element: AXUIElement

    public init(pid: pid_t, windowID: CGWindowID) throws {
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let status = OwnProcessAX.perform(for: pid) {
            AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        }
        guard status == .success, let windows = value as? [AXUIElement] else {
            throw AXWindowError.failed(status.rawValue)
        }
        for window in windows {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(window, &id) == .success, id == windowID {
                self.pid = pid
                self.windowID = windowID
                self.element = window
                AXUIElementSetMessagingTimeout(window, 0.25)
                return
            }
        }
        throw AXWindowError.notFound
    }

    public var size: CGSize? {
        var value: CFTypeRef?
        let status = OwnProcessAX.perform(for: pid) {
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        }
        guard status == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    public var position: CGPoint? {
        var value: CFTypeRef?
        let status = OwnProcessAX.perform(for: pid) {
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
        }
        guard status == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    public var isResizable: Bool {
        var settable: DarwinBoolean = false
        let status = OwnProcessAX.perform(for: pid) {
            AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable)
        }
        return status == .success
            && settable.boolValue
    }

    /// Requests a new size. The application may clamp it; read `size` back
    /// (or watch captured frames) for the size actually applied.
    public func setSize(_ size: CGSize) throws {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { throw AXWindowError.failed(-1) }
        let status = OwnProcessAX.perform(for: pid) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
        guard status == .success else { throw AXWindowError.failed(status.rawValue) }
    }

    public func setPosition(_ point: CGPoint) throws {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { throw AXWindowError.failed(-1) }
        let status = OwnProcessAX.perform(for: pid) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
        guard status == .success else { throw AXWindowError.failed(status.rawValue) }
    }

    public func raise() {
        OwnProcessAX.perform(for: pid) { _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
    }
}

extension AXWindow {
    public var subrole: String? { stringAttribute(kAXSubroleAttribute) }
    public var title: String? { stringAttribute(kAXTitleAttribute) }

    private func stringAttribute(_ name: String) -> String? {
        var value: CFTypeRef?
        let status = OwnProcessAX.perform(for: pid) { AXUIElementCopyAttributeValue(element, name as CFString, &value) }
        guard status == .success else { return nil }
        return value as? String
    }

    /// Makes this window the key window of its application and brings the
    /// application forward. Works from a background process, unlike
    /// `NSRunningApplication.activate`, which macOS 14+ may refuse.
    public func focus() {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        OwnProcessAX.perform(for: pid) {
            AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
    }

    /// Title bar button frames, in points relative to the window's top-left corner.
    public var controlFrames: (close: CGRect?, minimize: CGRect?, zoom: CGRect?, fullScreen: CGRect?) {
        OwnProcessAX.perform(for: pid) {
            guard let origin = Self.point(of: element) else { return (nil, nil, nil, nil) }
            func frame(_ attribute: String) -> CGRect? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                      let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                let button = value as! AXUIElement
                guard let position = Self.point(of: button), let size = Self.size(of: button),
                      size.width > 0, size.height > 0 else { return nil }
                return CGRect(x: position.x - origin.x, y: position.y - origin.y, width: size.width, height: size.height)
            }
            return (frame(kAXCloseButtonAttribute), frame(kAXMinimizeButtonAttribute), frame(kAXZoomButtonAttribute),
                    frame("AXFullScreenButton"))
        }
    }

    public var isMinimized: Bool { boolAttribute(kAXMinimizedAttribute) }
    public var isFullScreen: Bool { boolAttribute("AXFullScreen") }

    public func setMinimized(_ minimized: Bool) { setBoolAttribute(kAXMinimizedAttribute, minimized) }
    public func setFullScreen(_ fullScreen: Bool) { setBoolAttribute("AXFullScreen", fullScreen) }

    /// Presses the close button, as a click on it would.
    @discardableResult
    public func pressCloseButton() -> Bool {
        OwnProcessAX.perform(for: pid) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
            return AXUIElementPerformAction(value as! AXUIElement, kAXPressAction as CFString) == .success
        }
    }

    private func boolAttribute(_ name: String) -> Bool {
        var value: CFTypeRef?
        let status = OwnProcessAX.perform(for: pid) { AXUIElementCopyAttributeValue(element, name as CFString, &value) }
        return status == .success && (value as? Bool) == true
    }

    private func setBoolAttribute(_ name: String, _ flag: Bool) {
        OwnProcessAX.perform(for: pid) {
            _ = AXUIElementSetAttributeValue(element, name as CFString, (flag ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
        }
    }

    private static func point(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    /// The application's standard (top-level document) window IDs.
    public static func standardWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        standardWindowIDsIfAnswered(pid: pid) ?? []
    }

    /// The application's standard window IDs, or nil when it didn't answer
    /// (busy, hung): an empty set would claim it has none.
    public static func standardWindowIDsIfAnswered(pid: pid_t) -> Set<CGWindowID>? {
        OwnProcessAX.perform(for: pid) { standardWindowIDsDirect(pid: pid) }
    }

    private static func standardWindowIDsDirect(pid: pid_t) -> Set<CGWindowID>? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        var result = Set<CGWindowID>()
        for window in windows {
            AXUIElementSetMessagingTimeout(window, 0.25)
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            guard (subrole as? String) == (kAXStandardWindowSubrole as String) else { continue }
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(window, &id) == .success { result.insert(id) }
        }
        return result
    }
}
