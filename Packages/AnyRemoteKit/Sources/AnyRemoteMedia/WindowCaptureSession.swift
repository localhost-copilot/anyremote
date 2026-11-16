import AnyRemoteWire
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Capture")

/// A complete captured window image at its native backing resolution.
public struct CapturedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// SCK presentation time: when the host shows the frame (host clock).
    public let captureTimeNanos: UInt64
    /// When the frame reached our handler.
    public let deliveredTimeNanos: UInt64
    public let pointSize: CGSize
    public let scale: CGFloat
    /// What changed since the previous frame, in buffer pixels (top-left
    /// origin); nil if unknown.
    public var dirtyRects: [CGRect]?
    /// Set when this is one strip of a larger picture.
    public var tile: EncodedVideoFrame.Tile?

    public init(pixelBuffer: CVPixelBuffer, captureTimeNanos: UInt64, deliveredTimeNanos: UInt64,
                pointSize: CGSize, scale: CGFloat, dirtyRects: [CGRect]? = nil) {
        self.dirtyRects = dirtyRects
        self.pixelBuffer = pixelBuffer
        self.captureTimeNanos = captureTimeNanos
        self.deliveredTimeNanos = deliveredTimeNanos
        self.pointSize = pointSize
        self.scale = scale
    }
}

/// Captures exactly one window, unscaled, in full-range 4:4:4 (`444f`) so the
/// hardware HEVC encoder produces RExt 4:4:4 without a conversion pass.
///
/// The output buffer always matches the window's current pixel size. When the
/// window is resized, frames whose content no longer fills the configured
/// buffer are dropped while the stream is reconfigured; the viewer keeps
/// showing the previous frame meanwhile.
///
/// A window attached to another (a sheet) is captured together with its
/// parent, shrunk into the buffer, and a window that others are attached to
/// is captured with them (Chrome's link status bubble, one point left of the
/// window, added a black column down its left edge). When a frame shows more
/// than the window, the session switches to a display capture that includes
/// only this window, cropped to its frame (`windowFrameChanged` keeps the
/// crop on it).
///
/// Menus, popovers and alerts (`backdrop`) have glass that blurs what lies
/// behind them, which a capture of the window alone leaves out: macOS
/// renders their glass over nothing then, a flat dark gray. They are captured from the display
/// with the windows beneath them, cropped to their frame, with the corners
/// outside their rounded shape cut out again (`WindowShapeMask`).
public final class WindowCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public static let pixelFormat = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange

    public let windowID: CGWindowID
    private let queue = DispatchQueue(label: "anyremote.capture", qos: .userInteractive)
    private let handler: @Sendable (CapturedFrame) -> Void
    private let frameRate: Int
    private let pixelFormat: OSType
    private let backdrop: Bool
    private var stream: SCStream?
    private var filter: SCContentFilter?

    // Queue-confined.
    private var configuredPixelSize: (width: Int, height: Int) = (0, 0)
    private var reconfiguring = false
    private var pendingPixelSize: (width: Int, height: Int)?
    private var lastLoggedGeometry = ""
    /// The window's frame in global points (top-left origin).
    private var windowFrame: CGRect
    /// The captured size last compared with the window's own.
    private var checkedPoints: CGSize?
    /// The window's bounds at the last comparison, and since when they were so.
    private var boundsSince: (bounds: CGRect, nanos: UInt64)?
    private var switching = false
    /// Queue-confined. The crop takes the whole display (the window fills it).
    private var wholeDisplay = false
    /// Set in crop mode: the display the crop is relative to, and its scale.
    private var crop: (displayFrame: CGRect, scale: CGFloat)?
    /// The system's sharing indicator, in window points from the top-left
    /// corner; painted over in every frame (see `SharingIndicatorConcealer`).
    private var concealedRect: CGRect?
    /// The latest frame, kept only until the indicator is known: SCK sends
    /// nothing while the window doesn't change, so that frame is sent again
    /// with the indicator painted over. Only during the first seconds (the
    /// indicator appears when capture starts), since a kept buffer is one
    /// fewer for SCK's small pool.
    private var unconcealedFrame: CapturedFrame?
    private var firstFrameNanos: UInt64 = 0
    /// Backdrop mode: the window's shape at the configured size, and the
    /// latest frame while it isn't known yet (SCK sends nothing more while
    /// the screen there doesn't change).
    private var mask: WindowShapeMask?
    private var unmaskedFrame: CapturedFrame?
    private var shapeWindow: SCWindow?
    private var shapeDisplay: SCDisplay?
    private var shapeOthers: [SCWindow] = []

    public var onStop: (@Sendable (Error?) -> Void)?

    /// `alpha` captures premultiplied BGRA instead of `444f`; `backdrop`
    /// (which needs `alpha`) captures the window with what lies beneath it.
    public init(window: SCWindow, frameRate: Int = 60, alpha: Bool = false, backdrop: Bool = false,
                handler: @escaping @Sendable (CapturedFrame) -> Void) {
        self.windowID = window.windowID
        self.windowFrame = window.frame
        self.frameRate = frameRate
        self.pixelFormat = alpha ? kCVPixelFormatType_32BGRA : Self.pixelFormat
        self.backdrop = alpha && backdrop
        self.handler = handler
        super.init()
        self.filter = SCContentFilter(desktopIndependentWindow: window)
    }

    public func start() async throws {
        if backdrop {
            try await startCrop()
            return
        }
        guard let filter else { return }
        let scale = CGFloat(filter.pointPixelScale)
        let size = Self.pixelSize(points: filter.contentRect.size, scale: scale)
        let configuration = makeConfiguration(width: size.width, height: size.height)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync { configuredPixelSize = size }
        self.stream = stream
        try await stream.startCapture()
        log.info("capture started window=\(self.windowID) size=\(size.width)x\(size.height)")
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    /// The window moved or was resized (global points, top-left origin).
    public func windowFrameChanged(_ frame: CGRect) {
        queue.async { [self] in
            guard frame != windowFrame else { return }
            windowFrame = frame
            if crop != nil { requestCrop() }
        }
    }

    /// Where macOS draws its sharing indicator on the window (window points
    /// from the top-left corner), or nil.
    public func setConcealedRect(_ rect: CGRect?) {
        queue.async { [self] in
            guard rect != concealedRect else { return }
            concealedRect = rect
            guard rect != nil, let frame = unconcealedFrame else { return }
            unconcealedFrame = nil
            conceal(in: frame.pixelBuffer, scale: frame.scale)
            let now = HostClock.nowNanos()
            handler(CapturedFrame(pixelBuffer: frame.pixelBuffer, captureTimeNanos: now, deliveredTimeNanos: now,
                                  pointSize: frame.pointSize, scale: frame.scale))
        }
    }

    /// Queue-confined. Hands a frame on, keeping it while the indicator isn't known yet.
    private func deliver(_ frame: CapturedFrame) {
        if firstFrameNanos == 0 { firstFrameNanos = frame.deliveredTimeNanos }
        let early = frame.deliveredTimeNanos &- firstFrameNanos < 3_000_000_000
        unconcealedFrame = concealedRect == nil && early ? frame : nil
        handler(frame)
    }

    /// Queue-confined.
    private func conceal(in pixelBuffer: CVPixelBuffer, scale: CGFloat) {
        guard let concealedRect else { return }
        let pixels = CGRect(x: concealedRect.minX * scale, y: concealedRect.minY * scale,
                            width: concealedRect.width * scale, height: concealedRect.height * scale)
        SharingIndicatorConcealer.conceal(pixels, in: pixelBuffer)
    }

    /// Queue-confined. Restarts the capture as a display capture of only this window.
    private func switchToCrop() {
        guard !switching, let old = stream else { return }
        switching = true
        Task {
            try? await old.stopCapture()
            // Leaving full screen, the window is out of the on-screen list
            // until its Space's animation is over (about a second): it is
            // looked for again meanwhile rather than the capture given up.
            var attempt = 0
            while true {
                do {
                    try await startCrop()
                    log.notice("window \(self.windowID) is captured from its display")
                    return
                } catch let error as SCStreamError where (error.code == .noWindowList || error.code == .noDisplayList) && attempt < 20 {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 150_000_000)
                } catch {
                    log.error("cropped capture failed: \(error.localizedDescription, privacy: .public)")
                    onStop?(error)
                    return
                }
            }
        }
    }

    /// Captures the window from its display, cropped to its frame: alone, or
    /// in backdrop mode with the windows beneath it.
    private func startCrop() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw SCStreamError(.noWindowList)
        }
        // The window server's frame: right after a window goes full screen,
        // the shareable content can still have the one from before, which
        // would crop the old place of a display showing something else now.
        let frame = currentBounds() ?? window.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) })
            ?? content.displays.first(where: { $0.frame.intersects(frame) }) else {
            throw SCStreamError(.noDisplayList)
        }
        var included = [window]
        if backdrop {
            // Only what is beneath: whatever covers the window on the host
            // isn't part of it. The viewer's own windows (in loopback) aren't
            // the host's.
            let below = (CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow], windowID) as? [[CFString: Any]] ?? [])
                .compactMap { $0[kCGWindowNumber] as? CGWindowID }
            let ids = Set(below)
            let ownPID = ProcessInfo.processInfo.processIdentifier
            included += content.windows.filter {
                ids.contains($0.windowID) && $0.owningApplication?.processID != ownPID
                    && $0.frame.intersects(frame)
            }
        }
        // Full screen (Chrome's is a group, with its toolbar strips): a
        // filter of chosen windows sends one frame of a full-screen Space and
        // then nothing, while the whole display keeps coming, and shows only
        // this window there anyway.
        let whole = frame == display.frame && !backdrop
        let filter = whole
            ? SCContentFilter(display: display, excludingWindows: [])
            : SCContentFilter(display: display, including: included)
        if whole { log.notice("window \(self.windowID) fills display \(display.displayID); capturing all of it") }
        let scale = CGFloat(filter.pointPixelScale)
        let (configuration, size) = queue.sync { () -> (SCStreamConfiguration, (width: Int, height: Int)) in
            crop = (display.frame, scale)
            wholeDisplay = whole
            windowFrame = frame
            shapeWindow = window
            shapeDisplay = display
            shapeOthers = content.windows.filter { $0.windowID != window.windowID && $0.frame.intersects(frame) }
            let size = Self.pixelSize(points: frame.size, scale: scale)
            let configuration = makeConfiguration(width: size.width, height: size.height)
            configuration.sourceRect = cropRect
            return (configuration, size)
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            configuredPixelSize = size
            self.stream = stream
            self.filter = filter
            switching = false
        }
        // The shape is captured while the stream starts: a menu should
        // appear no later than it did when captured alone.
        if backdrop { queue.async { [self] in refreshMask(size: size) } }
        try await stream.startCapture()
        if backdrop {
            log.info("capture started window=\(self.windowID) size=\(size.width)x\(size.height) with its backdrop")
        }
    }

    /// Queue-confined. Whether the window is still where the crop is. The
    /// crop follows a moved window only after an asynchronous reconfigure;
    /// frames cut from the old place would show it shifted and its corners
    /// cut in the wrong place, which made dragged alerts shake. Those frames
    /// are dropped: a window's content rarely changes while it is dragged,
    /// and the viewer moves its own window meanwhile.
    private func cropIsOnWindow() -> Bool {
        guard let frame = currentBounds() else { return true }
        guard frame != windowFrame else { return !reconfiguring }
        windowFrame = frame
        requestCrop()
        return false
    }

    /// Queue-confined. Whether a frame of this size shows more than the
    /// window: the windows attached to it, or that it is attached to. The
    /// size is compared with the window's bounds now, and after the first
    /// frame only once they have held for a moment: while a window shrinks,
    /// its frames can still show the larger size.
    private func isGrouped(_ points: CGSize) -> Bool {
        let now = HostClock.nowNanos()
        let first = boundsSince == nil
        guard let bounds = currentBounds() else { return false }
        if boundsSince?.bounds != bounds { boundsSince = (bounds, now) }
        guard first || now - (boundsSince?.nanos ?? now) >= 300_000_000 else {
            checkedPoints = nil // looks again at the next frame
            return false
        }
        checkedPoints = points
        // Full screen on a display of its own (a virtual display for remote
        // windows): the display shows only this window and what goes with
        // it, toolbars and menus included, and its capture keeps coming.
        if !backdrop, Self.displayBounds().contains(bounds) {
            log.notice("window \(self.windowID) fills its display")
            return true
        }
        guard points.width > bounds.width + 0.5 || points.height > bounds.height + 0.5 else { return false }
        log.notice("window \(self.windowID) captured as \(points.debugDescription) but is \(bounds.size.debugDescription)")
        return true
    }

    /// The window's frame as the window server has it now.
    private func currentBounds() -> CGRect? {
        var values: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(windowID))]
        guard let ids = CFArrayCreate(nil, &values, 1, nil),
              let info = (CGWindowListCreateDescriptionFromArray(ids) as? [[CFString: Any]])?.first,
              let bounds = info[kCGWindowBounds] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// Queue-confined. Captures the window alone once, for its shape at this
    /// pixel size: from its display, every other window there excluded, and
    /// cropped like the stream. A desktop-independent capture would show a
    /// menu or sheet together with the window it belongs to, shrunk to its
    /// size, and including only the window still brings that one along.
    private func refreshMask(size: (width: Int, height: Int)) {
        guard backdrop, shapeWindow != nil, let display = shapeDisplay else { return }
        let others = shapeOthers
        let configuration = makeConfiguration(width: size.width, height: size.height)
        configuration.sourceRect = cropRect
        Task {
            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: others), configuration: configuration)
                guard let mask = WindowShapeMask(image: image) else { return }
                queue.async { [self] in
                    guard mask.width == configuredPixelSize.width, mask.height == configuredPixelSize.height else {
                        log.debug("shape of window \(self.windowID) is \(mask.width)x\(mask.height), not the crop's size")
                        return
                    }
                    self.mask = mask
                    guard let frame = unmaskedFrame, mask.fits(frame.pixelBuffer) else { return }
                    unmaskedFrame = nil
                    mask.apply(to: frame.pixelBuffer)
                    let now = HostClock.nowNanos()
                    deliver(CapturedFrame(pixelBuffer: frame.pixelBuffer, captureTimeNanos: now, deliveredTimeNanos: now,
                                          pointSize: frame.pointSize, scale: frame.scale))
                }
            } catch {
                log.error("shape capture of window \(self.windowID) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Queue-confined. The crop in display-local points.
    private var cropRect: CGRect {
        guard let crop else { return .zero }
        return windowFrame.offsetBy(dx: -crop.displayFrame.minX, dy: -crop.displayFrame.minY)
    }

    /// Queue-confined. Follows the window with the crop (and its size).
    private func requestCrop() {
        guard let stream, let crop, !switching else { return }
        // Moved to another display (remote windows follow the viewer's
        // screens): the crop of the old one would point outside it, and the
        // picture would stop. The capture starts again on the new one.
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        guard crop.displayFrame.contains(center) || !Self.anyOtherDisplay(contains: center, than: crop.displayFrame) else {
            log.notice("window \(self.windowID) moved to another display; capturing it from there")
            switchToCrop()
            return
        }
        // Out of full screen: the display has other windows on it again.
        guard !wholeDisplay || windowFrame == crop.displayFrame else {
            log.notice("window \(self.windowID) no longer fills its display")
            switchToCrop()
            return
        }
        guard !reconfiguring else {
            pendingPixelSize = configuredPixelSize
            return
        }
        reconfiguring = true
        let size = Self.pixelSize(points: windowFrame.size, scale: crop.scale)
        let configuration = makeConfiguration(width: size.width, height: size.height)
        configuration.sourceRect = cropRect
        stream.updateConfiguration(configuration) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.reconfiguring = false
                if let error {
                    log.error("crop reconfigure failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    let resized = size != self.configuredPixelSize
                    self.configuredPixelSize = size
                    if resized, self.backdrop {
                        self.mask = nil
                        self.refreshMask(size: size)
                    }
                }
                if self.pendingPixelSize != nil {
                    self.pendingPixelSize = nil
                    self.requestCrop()
                }
            }
        }
    }

    /// The bounds of every active display.
    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Whether a display other than the one at `frame` holds `point` (a
    /// window parked off every display stays captured where it was).
    private static func anyOtherDisplay(contains point: CGPoint, than frame: CGRect) -> Bool {
        displayBounds().contains { $0 != frame && $0.contains(point) }
    }

    private func makeConfiguration(width: Int, height: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = pixelFormat
        configuration.colorSpaceName = CGColorSpace.displayP3
        if pixelFormat == Self.pixelFormat {
            configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        } else {
            configuration.backgroundColor = .clear
        }
        // 1.5x the cadence: at exactly the refresh period SCK skips frames whose
        // timestamps arrive a little early (measured: ~50 of 60 delivered).
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate * 3 / 2))
        // One more than the encoder's in-flight and waiting frames need: the
        // last frame stays out of the pool for `UnchangedFrameFilter`.
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.capturesAudio = false
        return configuration
    }

    /// `contentRect` is where the window landed in the buffer. When the window
    /// outgrew the configured buffer, SCK shrank it by `contentScale`, so the
    /// window's real size is `contentRect / contentScale`.
    static func windowPointSize(contentRect: CGRect, contentScale: CGFloat) -> CGSize {
        guard contentScale > 0 else { return contentRect.size }
        return CGSize(width: contentRect.width / contentScale, height: contentRect.height / contentScale)
    }

    static func pixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        // HEVC needs even dimensions for robust chroma siting across decoders.
        let width = max(2, Int((points.width * scale).rounded()) & ~1)
        let height = max(2, Int((points.height * scale).rounded()) & ~1)
        return (width, height)
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                  as? [[SCStreamFrameInfo: Any]])?.first,
              let statusValue = attachments[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let rectDictionary = attachments[.contentRect],
              let contentRect = CGRect(dictionaryRepresentation: rectDictionary as! CFDictionary)
        else { return }

        guard stream === self.stream, !switching else { return }
        if let crop {
            // Display capture: the buffer is the crop, at the display's scale.
            guard CVPixelBufferGetWidth(pixelBuffer) == configuredPixelSize.width,
                  CVPixelBufferGetHeight(pixelBuffer) == configuredPixelSize.height,
                  cropIsOnWindow() else { return }
            conceal(in: pixelBuffer, scale: crop.scale)
            if wholeDisplay { SharingIndicatorConcealer.coverTopRow(in: pixelBuffer) }
            let frame = CapturedFrame(
                pixelBuffer: pixelBuffer,
                captureTimeNanos: Self.displayTime(of: sampleBuffer),
                deliveredTimeNanos: HostClock.nowNanos(),
                pointSize: CGSize(width: CGFloat(configuredPixelSize.width) / crop.scale,
                                  height: CGFloat(configuredPixelSize.height) / crop.scale),
                scale: crop.scale
            )
            if backdrop {
                // Without its shape the frame would show square corners.
                guard let mask, mask.fits(pixelBuffer) else {
                    unmaskedFrame = frame
                    return
                }
                unmaskedFrame = nil
                mask.apply(to: pixelBuffer)
            }
            deliver(frame)
            return
        }

        let scale = (attachments[.scaleFactor] as? CGFloat) ?? 1
        let contentScale = (attachments[.contentScale] as? CGFloat) ?? 1
        let windowPoints = Self.windowPointSize(contentRect: contentRect, contentScale: contentScale)
        let wanted = Self.pixelSize(points: windowPoints, scale: scale)
        let geometry = "\(contentRect) scale=\(scale) contentScale=\(contentScale) buffer=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))"
        if geometry != lastLoggedGeometry {
            lastLoggedGeometry = geometry
            log.debug("capture geometry \(geometry, privacy: .public)")
        }
        if windowPoints != checkedPoints, isGrouped(windowPoints) {
            switchToCrop()
            return
        }

        guard wanted == configuredPixelSize, abs(contentScale - 1) < 0.001 else {
            requestPixelSize(wanted)
            return
        }

        conceal(in: pixelBuffer, scale: scale)
        deliver(CapturedFrame(
            pixelBuffer: pixelBuffer,
            captureTimeNanos: Self.displayTime(of: sampleBuffer),
            deliveredTimeNanos: HostClock.nowNanos(),
            pointSize: windowPoints,
            scale: scale
        ))
    }

    /// SCK stamps a frame with the time it is shown on the host's screen.
    /// That is usually still ahead when the frame is handed over (measured:
    /// 9 ms on average, up to 15 ms); the encoder sends the difference so the
    /// viewer counts latency from the handover. The stamps themselves are
    /// exactly one refresh apart, which the viewer paces presentation by.
    static func displayTime(of sampleBuffer: CMSampleBuffer) -> UInt64 {
        let shown = HostClock.nanos(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        return shown > 0 ? shown : HostClock.nowNanos()
    }

    /// Queue-confined. Coalesces resize requests while one is in flight.
    private func requestPixelSize(_ size: (width: Int, height: Int)) {
        guard !reconfiguring else {
            pendingPixelSize = size
            return
        }
        guard let stream, crop == nil, !switching, size != configuredPixelSize else { return }
        reconfiguring = true
        let configuration = makeConfiguration(width: size.width, height: size.height)
        stream.updateConfiguration(configuration) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.reconfiguring = false
                if let error {
                    log.error("capture reconfigure failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    self.configuredPixelSize = size
                }
                if let pending = self.pendingPixelSize {
                    self.pendingPixelSize = nil
                    self.requestPixelSize(pending)
                }
            }
        }
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.error("capture stopped: \(error.localizedDescription, privacy: .public)")
        onStop?(error)
    }
}

