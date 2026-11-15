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
    /// SCK presentation time (host clock).
    public let captureTimeNanos: UInt64
    /// When the frame reached our handler.
    public let deliveredTimeNanos: UInt64
    public let pointSize: CGSize
    public let scale: CGFloat
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
/// parent, shrunk into the buffer. When the first frame shows more than the
/// window, the session switches to a display capture that includes only this
/// window, cropped to its frame (`windowFrameChanged` keeps the crop on it).
public final class WindowCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public static let pixelFormat = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange

    public let windowID: CGWindowID
    private let queue = DispatchQueue(label: "anyremote.capture", qos: .userInteractive)
    private let handler: @Sendable (CapturedFrame) -> Void
    private let frameRate: Int
    private let pixelFormat: OSType
    private var stream: SCStream?
    private var filter: SCContentFilter?

    // Queue-confined.
    private var configuredPixelSize: (width: Int, height: Int) = (0, 0)
    private var reconfiguring = false
    private var pendingPixelSize: (width: Int, height: Int)?
    private var lastLoggedGeometry = ""
    /// The window's frame in global points (top-left origin).
    private var windowFrame: CGRect
    private var checkedGroup = false
    private var switching = false
    /// Set in crop mode: the display the crop is relative to, and its scale.
    private var crop: (displayFrame: CGRect, scale: CGFloat)?

    public var onStop: (@Sendable (Error?) -> Void)?

    /// `alpha` captures premultiplied BGRA instead of `444f`.
    public init(window: SCWindow, frameRate: Int = 60, alpha: Bool = false,
                handler: @escaping @Sendable (CapturedFrame) -> Void) {
        self.windowID = window.windowID
        self.windowFrame = window.frame
        self.frameRate = frameRate
        self.pixelFormat = alpha ? kCVPixelFormatType_32BGRA : Self.pixelFormat
        self.handler = handler
        super.init()
        self.filter = SCContentFilter(desktopIndependentWindow: window)
    }

    public func start() async throws {
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

    /// Queue-confined. Restarts the capture as a display capture of only this window.
    private func switchToCrop() {
        guard !switching, let old = stream else { return }
        switching = true
        Task {
            try? await old.stopCapture()
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    throw SCStreamError(.noWindowList)
                }
                let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
                guard let display = content.displays.first(where: { $0.frame.contains(center) })
                    ?? content.displays.first(where: { $0.frame.intersects(window.frame) }) else {
                    throw SCStreamError(.noDisplayList)
                }
                let filter = SCContentFilter(display: display, including: [window])
                let scale = CGFloat(filter.pointPixelScale)
                let (configuration, size) = queue.sync { () -> (SCStreamConfiguration, (width: Int, height: Int)) in
                    crop = (display.frame, scale)
                    windowFrame = window.frame
                    let size = Self.pixelSize(points: window.frame.size, scale: scale)
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
                try await stream.startCapture()
                log.notice("window \(self.windowID) is part of a group; capturing it cropped from its display")
            } catch {
                log.error("cropped capture failed: \(error.localizedDescription, privacy: .public)")
                onStop?(error)
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
                    self.configuredPixelSize = size
                }
                if self.pendingPixelSize != nil {
                    self.pendingPixelSize = nil
                    self.requestCrop()
                }
            }
        }
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
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = 4
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
                  CVPixelBufferGetHeight(pixelBuffer) == configuredPixelSize.height else { return }
            handler(CapturedFrame(
                pixelBuffer: pixelBuffer,
                captureTimeNanos: HostClock.nanos(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                deliveredTimeNanos: HostClock.nowNanos(),
                pointSize: CGSize(width: CGFloat(configuredPixelSize.width) / crop.scale,
                                  height: CGFloat(configuredPixelSize.height) / crop.scale),
                scale: crop.scale
            ))
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
        if !checkedGroup {
            checkedGroup = true
            // More than the window itself: it was captured with the windows it's attached to.
            if windowPoints.width > windowFrame.width + 8 || windowPoints.height > windowFrame.height + 8 {
                log.notice("window \(self.windowID) captured as \(windowPoints.debugDescription) but is \(self.windowFrame.size.debugDescription)")
                switchToCrop()
                return
            }
        }

        guard wanted == configuredPixelSize, abs(contentScale - 1) < 0.001 else {
            requestPixelSize(wanted)
            return
        }

        handler(CapturedFrame(
            pixelBuffer: pixelBuffer,
            captureTimeNanos: HostClock.nanos(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
            deliveredTimeNanos: HostClock.nowNanos(),
            pointSize: windowPoints,
            scale: scale
        ))
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
