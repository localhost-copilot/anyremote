import CGVirtualDisplayPrivate
import CoreGraphics
import Foundation
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "VirtualDisplay")

/// A HiDPI virtual display, so a headless Mac mini (or one attached to a 1x
/// monitor) renders shared windows at 2x and has room for windows larger
/// than its physical screen.
///
/// The display exists while this object lives; macOS removes it when the
/// process exits.
public final class VirtualDisplay: @unchecked Sendable {
    public let displayID: CGDirectDisplayID
    /// "AR": the vendor of every display this app makes.
    public static let vendorID: UInt32 = 0x4152
    public private(set) var pointSize: CGSize
    private let display: CGVirtualDisplay
    private let refreshRate: Double

    /// - Parameters:
    ///   - maximumPointSize: the largest size `resize(to:)` may set later.
    ///   - productID: tells displays apart; two displays with the same one
    ///     can't exist at once (macOS keys their arrangement on it).
    public init?(pointSize: CGSize, maximumPointSize: CGSize? = nil, refreshRate: Double = 60, name: String = "AnyRemote",
                 productID: UInt32 = 1) {
        let maximum = maximumPointSize ?? pointSize
        let pixelWidth = UInt32(max(maximum.width, pointSize.width) * 2)
        let pixelHeight = UInt32(max(maximum.height, pointSize.height) * 2)
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue(label: "anyremote.virtual-display")
        descriptor.name = name
        descriptor.maxPixelsWide = pixelWidth
        descriptor.maxPixelsHigh = pixelHeight
        // A Retina-like ~220 ppi, so macOS treats it as a HiDPI panel.
        descriptor.sizeInMillimeters = CGSize(width: Double(pixelWidth) / 220 * 25.4,
                                              height: Double(pixelHeight) / 220 * 25.4)
        descriptor.vendorID = Self.vendorID
        descriptor.productID = productID
        descriptor.serialNum = 0x0001
        descriptor.terminationHandler = { _, _ in log.notice("virtual display terminated") }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            log.error("CGVirtualDisplay creation failed")
            return nil
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        // With hiDPI set, a mode's width/height are points rendered at 2x.
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(pointSize.width), height: UInt(pointSize.height), refreshRate: refreshRate),
        ]
        guard display.apply(settings) else {
            log.error("CGVirtualDisplay applySettings failed")
            return nil
        }
        self.display = display
        self.displayID = display.displayID
        self.pointSize = pointSize
        self.refreshRate = refreshRate
        log.info("virtual display \(display.displayID) \(Int(pointSize.width))x\(Int(pointSize.height))pt @2x")
    }

    /// macOS may put a new display into a mirror set with an existing one
    /// (the physical monitor then shows a scaled copy of the virtual display).
    /// Makes the virtual display an extended display to the right of the
    /// main one instead. Returns false if the display never came online.
    @discardableResult
    public func makeExtended(timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while CGDisplayIsOnline(displayID) == 0 {
            guard Date() < deadline else { return false }
            usleep(50_000)
        }
        let others = Self.onlineDisplays().filter { $0 != displayID }
        let mirrored = CGDisplayIsInMirrorSet(displayID) != 0
            || others.contains { CGDisplayMirrorsDisplay($0) == displayID }
        let main = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(main == displayID ? (others.first ?? main) : main)
        let placed = CGDisplayBounds(displayID)
        let overlaps = placed.intersects(mainBounds)
        guard mirrored || overlaps || main == displayID else { return true }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        if mirrored {
            CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
            for other in others where CGDisplayMirrorsDisplay(other) == displayID {
                CGConfigureDisplayMirrorOfDisplay(config, other, kCGNullDirectDisplay)
            }
        }
        CGConfigureDisplayOrigin(config, displayID, Int32(mainBounds.maxX), Int32(mainBounds.minY))
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        log.info("virtual display made extended (was mirrored: \(mirrored)): \(result.rawValue)")
        return result == .success
    }

    /// Switches to a new HiDPI mode of `pointSize` (within the maximum given at creation).
    @discardableResult
    public func resize(to pointSize: CGSize) -> Bool {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(pointSize.width), height: UInt(pointSize.height), refreshRate: refreshRate),
        ]
        guard display.apply(settings) else {
            log.error("virtual display resize to \(pointSize.debugDescription, privacy: .public) failed")
            return false
        }
        self.pointSize = pointSize
        selectHiDPIMode()
        log.info("virtual display \(self.displayID) now \(Int(pointSize.width))x\(Int(pointSize.height))pt @2x")
        return true
    }

    public func waitUntilOnline(timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while CGDisplayIsOnline(displayID) == 0 {
            guard Date() < deadline else { return false }
            usleep(20_000)
        }
        return true
    }

    /// Takes `source`'s place: the virtual display moves to its position (so
    /// it becomes the main display if `source` was) and `source` mirrors it,
    /// showing a scaled copy. Undone by `release(source:)`, and by macOS when
    /// this process exits.
    public func replace(_ source: CGDirectDisplayID) -> Bool {
        guard waitUntilOnline() else { return false }
        let origin = CGDisplayBounds(source).origin
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
        CGConfigureDisplayOrigin(config, displayID, Int32(origin.x), Int32(origin.y))
        CGConfigureDisplayMirrorOfDisplay(config, source, displayID)
        if let mode = hiDPIMode { CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil) }
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        log.notice("virtual display \(self.displayID) replaces display \(source): \(result.rawValue)")
        guard result == .success else { return false }
        // macOS may rearrange a new mirror set; put it back where the display was.
        if CGDisplayBounds(displayID).origin != origin {
            var again: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&again) == .success, let again {
                CGConfigureDisplayOrigin(again, displayID, Int32(origin.x), Int32(origin.y))
                _ = CGCompleteDisplayConfiguration(again, .forSession)
            }
        }
        return true
    }

    /// The mode of `pointSize` rendered at 2x. With a mirror or a large
    /// maximum size macOS may otherwise pick the same pixels at 1x.
    private var hiDPIMode: CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? []
        return modes.first {
            $0.width == Int(pointSize.width) && $0.height == Int(pointSize.height) && $0.pixelWidth == $0.width * 2
        }
    }

    /// The new mode list takes a moment after `apply`; until then setting a
    /// mode fails.
    private func selectHiDPIMode() {
        for attempt in 0..<10 {
            if attempt > 0 { usleep(50_000) }
            guard let mode = hiDPIMode, let current = CGDisplayCopyDisplayMode(displayID) else { continue }
            if current.pixelWidth == mode.pixelWidth, current.width == mode.width { return }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
            CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
            let result = CGCompleteDisplayConfiguration(config, .forSession)
            if result == .success {
                log.info("virtual display \(self.displayID) set to its 2x mode")
                return
            }
        }
        log.error("virtual display \(self.displayID) stays at 1x")
    }

    /// Ends `source` mirroring this display; it gets its own picture back.
    public func release(source: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayMirrorOfDisplay(config, source, kCGNullDirectDisplay)
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        log.notice("display \(source) no longer mirrors virtual display \(self.displayID): \(result.rawValue)")
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// Global top-left bounds in points, once the window server placed it.
    public var bounds: CGRect { CGDisplayBounds(displayID) }

    /// True when some online display already renders at 2x or more.
    public static var hasHiDPIDisplay: Bool {
        onlineDisplays().contains { id in
            guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return false }
            return mode.pixelWidth >= mode.width * 2
        }
    }
}
