import AnyRemoteWire
import AppKit
import CoreGraphics
import ImageIO
import OSLog
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Host")

/// Enumerates shareable windows and the displays they live on.
enum HostWindows {
    /// Top-level windows a viewer may open.
    static func shareable(excludingPID ownPID: pid_t?, includeOwnWindowIDs: Set<CGWindowID>)
        async throws -> [(SCWindow, WindowSummary)]
    {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.compactMap { window in
            guard window.windowLayer == 0,
                  window.frame.width >= 100, window.frame.height >= 60,
                  let app = window.owningApplication else { return nil }
            if app.processID == ownPID && !includeOwnWindowIDs.contains(window.windowID) { return nil }
            return (window, summary(window, app: app))
        }
    }

    static func summary(_ window: SCWindow, app: SCRunningApplication) -> WindowSummary {
        WindowSummary(windowID: window.windowID, pid: app.processID, applicationName: app.applicationName,
                      bundleIdentifier: app.bundleIdentifier.isEmpty ? nil : app.bundleIdentifier,
                      title: window.title ?? "", frame: window.frame)
    }

    static func scWindow(id: CGWindowID) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.first { $0.windowID == id }
    }

    /// Displays in global top-left points, with the menu bar and Dock removed
    /// from `visibleFrame`.
    @MainActor
    static func displays(virtualDisplayIDs: Set<CGDirectDisplayID>) -> [DisplaySummary] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            func flip(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
            }
            return DisplaySummary(displayID: id, frame: flip(screen.frame), visibleFrame: flip(screen.visibleFrame),
                                  scale: screen.backingScaleFactor, isVirtual: virtualDisplayIDs.contains(id))
        }
    }

    /// JPEG thumbnails, longest side at most `maximumPixels`.
    static func thumbnails(for windows: [SCWindow], maximumPixels: Int) async -> [UInt32: Data] {
        guard maximumPixels > 0 else { return [:] }
        return await withTaskGroup(of: (UInt32, Data?).self) { group in
            for unsafeWindow in windows {
                nonisolated(unsafe) let window = unsafeWindow
                group.addTask {
                    let longest = max(window.frame.width, window.frame.height, 1)
                    let factor = min(1, CGFloat(maximumPixels) / longest)
                    let configuration = SCStreamConfiguration()
                    configuration.width = max(16, Int(window.frame.width * factor))
                    configuration.height = max(16, Int(window.frame.height * factor))
                    configuration.showsCursor = false
                    configuration.ignoreShadowsSingleWindow = true
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                                  configuration: configuration)
                    else { return (window.windowID, nil) }
                    return (window.windowID, encode(image, type: .jpeg, quality: 0.75))
                }
            }
            var result: [UInt32: Data] = [:]
            for await (id, data) in group {
                if let data { result[id] = data }
            }
            return result
        }
    }

    /// 64×64 pt PNG application icons keyed by bundle identifier.
    @MainActor
    static func icons(for summaries: [WindowSummary], cache: inout [String: Data]) -> [String: Data] {
        var result: [String: Data] = [:]
        for summary in summaries {
            guard let bundle = summary.bundleIdentifier else { continue }
            if let cached = cache[bundle] {
                result[bundle] = cached
                continue
            }
            guard let icon = NSRunningApplication(processIdentifier: summary.pid)?.icon else { continue }
            var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
            guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                  let data = encode(image, type: .png) else { continue }
            cache[bundle] = data
            result[bundle] = data
        }
        return result
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// A lightweight on-screen window record from the window server.
struct WindowServerWindow: Sendable {
    var id: CGWindowID
    var pid: pid_t
    var layer: Int
    var frame: CGRect
    var ownerName: String
    var title: String
    var alpha: Double

    /// Front-to-back on-screen windows.
    static func onScreen() -> [WindowServerWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString: Any]] else { return [] }
        return list.compactMap(parse)
    }

    static func describe(_ id: CGWindowID) -> WindowServerWindow? {
        // A CFArray of raw CGWindowID values, not of boxed objects.
        var values: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        guard let ids = CFArrayCreate(nil, &values, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(ids) as? [[CFString: Any]],
              let first = list.first else { return nil }
        return parse(first)
    }

    private static func parse(_ info: [CFString: Any]) -> WindowServerWindow? {
        guard let id = info[kCGWindowNumber] as? CGWindowID,
              let pid = info[kCGWindowOwnerPID] as? pid_t,
              let boundsDictionary = info[kCGWindowBounds] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
        return WindowServerWindow(id: id, pid: pid, layer: (info[kCGWindowLayer] as? Int) ?? 0, frame: bounds,
                                  ownerName: (info[kCGWindowOwnerName] as? String) ?? "",
                                  title: (info[kCGWindowName] as? String) ?? "",
                                  alpha: (info[kCGWindowAlpha] as? Double) ?? 1)
    }
}
