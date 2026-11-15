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
    public let pointSize: CGSize
    private let display: CGVirtualDisplay

    public init?(pointSize: CGSize, refreshRate: Double = 60, name: String = "AnyRemote") {
        let pixelWidth = UInt32(pointSize.width * 2)
        let pixelHeight = UInt32(pointSize.height * 2)
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue(label: "anyremote.virtual-display")
        descriptor.name = name
        descriptor.maxPixelsWide = pixelWidth
        descriptor.maxPixelsHigh = pixelHeight
        // A Retina-like ~220 ppi, so macOS treats it as a HiDPI panel.
        descriptor.sizeInMillimeters = CGSize(width: Double(pixelWidth) / 220 * 25.4,
                                              height: Double(pixelHeight) / 220 * 25.4)
        descriptor.vendorID = 0x4152 // "AR"
        descriptor.productID = 0x0001
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
