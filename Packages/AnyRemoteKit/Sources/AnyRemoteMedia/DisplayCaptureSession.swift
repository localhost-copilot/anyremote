import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Capture")

/// Something that delivers `CapturedFrame`s for one stream.
public protocol FrameCapturing: AnyObject, Sendable {
    var onStop: (@Sendable (Error?) -> Void)? { get set }
    func start() async throws
    func stop() async
}

extension WindowCaptureSession: FrameCapturing {}

/// Captures a whole display (the full desktop) at its native pixel size, in
/// the same full-range 4:4:4 format as window capture, without the cursor:
/// the viewer draws the host's cursor locally.
///
/// SCK only delivers a frame when something on the display changed, so an
/// idle desktop costs nothing. When the display's mode changes (another
/// resolution, a different scale), `displayChanged` reconfigures the buffer
/// size; frames of the old size are dropped meanwhile.
public final class DisplayCaptureSession: NSObject, FrameCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let idLock = NSLock()
    private var currentDisplayID: CGDirectDisplayID
    /// The display being captured; `switchDisplay(to:)` changes it.
    public var displayID: CGDirectDisplayID {
        idLock.lock(); defer { idLock.unlock() }
        return currentDisplayID
    }
    private let queue = DispatchQueue(label: "anyremote.capture.display", qos: .userInteractive)
    private let handler: @Sendable (CapturedFrame) -> Void
    private let frameRate: Int
    private let excludedProcessID: pid_t?
    private let exceptedWindowIDs: Set<CGWindowID>
    private var stream: SCStream?

    // Queue-confined.
    private var configuredPixelSize: (width: Int, height: Int) = (0, 0)
    private var scale: CGFloat = 1
    private var reconfiguring = false
    private var pending: (points: CGSize, scale: CGFloat)?

    public var onStop: (@Sendable (Error?) -> Void)?

    /// - Parameter excludingProcessID: an app whose windows are left out of
    ///   the picture, including ones it opens later (for development: the
    ///   viewer itself, when it shows this same Mac).
    public init(displayID: CGDirectDisplayID, frameRate: Int = 60, excludingProcessID: pid_t? = nil,
                exceptingWindowIDs: Set<CGWindowID> = [],
                handler: @escaping @Sendable (CapturedFrame) -> Void) {
        self.exceptedWindowIDs = exceptingWindowIDs
        self.currentDisplayID = displayID
        self.frameRate = frameRate
        self.excludedProcessID = excludingProcessID
        self.handler = handler
        super.init()
    }

    public func start() async throws {
        let displayID = displayID
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // A display that just appeared (dynamic resolution) takes a moment to be listed.
        for _ in 0..<20 where !content.displays.contains(where: { $0.displayID == displayID }) {
            try await Task.sleep(for: .milliseconds(100))
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw SCStreamError(.noDisplayList)
        }
        let excluded = content.applications.filter { $0.processID == excludedProcessID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded,
                                     exceptingWindows: content.windows.filter { exceptedWindowIDs.contains($0.windowID) })
        let scale = CGFloat(filter.pointPixelScale)
        let size = WindowCaptureSession.pixelSize(points: display.frame.size, scale: scale)
        let configuration = makeConfiguration(width: size.width, height: size.height)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            configuredPixelSize = size
            self.scale = scale
            self.stream = stream
        }
        try await stream.startCapture()
        log.info("display capture started display=\(self.displayID) size=\(size.width)x\(size.height) @\(scale)x")
    }

    public func stop() async {
        let stream = queue.sync { () -> SCStream? in
            let current = self.stream
            self.stream = nil
            return current
        }
        try? await stream?.stopCapture()
    }

    /// Captures another display from now on (same stream, new picture).
    public func switchDisplay(to displayID: CGDirectDisplayID) async throws {
        await stop()
        idLock.withLock { currentDisplayID = displayID }
        queue.sync {
            reconfiguring = false
            pending = nil
        }
        try await start()
    }

    /// The display now has this size (points) and backing scale.
    public func displayChanged(pointSize: CGSize, scale: CGFloat) {
        queue.async { [self] in
            guard !reconfiguring else {
                pending = (pointSize, scale)
                return
            }
            reconfigure(pointSize: pointSize, scale: scale)
        }
    }

    /// Queue-confined.
    private func reconfigure(pointSize: CGSize, scale: CGFloat) {
        let size = WindowCaptureSession.pixelSize(points: pointSize, scale: scale)
        guard let stream, size != configuredPixelSize else { return }
        reconfiguring = true
        let configuration = makeConfiguration(width: size.width, height: size.height)
        stream.updateConfiguration(configuration) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.reconfiguring = false
                if let error {
                    log.error("display capture reconfigure failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    self.configuredPixelSize = size
                    self.scale = scale
                    log.info("display capture now \(size.width)x\(size.height) @\(scale)x")
                }
                if let pending = self.pending {
                    self.pending = nil
                    self.reconfigure(pointSize: pending.points, scale: pending.scale)
                }
            }
        }
    }

    private func makeConfiguration(width: Int, height: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = WindowCaptureSession.pixelFormat
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        // 1.5x the cadence: at exactly the refresh period SCK skips frames whose
        // timestamps arrive a little early (measured: ~50 of 60 delivered).
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate * 3 / 2))
        configuration.queueDepth = 4
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.capturesAudio = false
        return configuration
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, stream === self.stream,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                  as? [[SCStreamFrameInfo: Any]])?.first,
              let statusValue = attachments[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetWidth(pixelBuffer) == configuredPixelSize.width,
              CVPixelBufferGetHeight(pixelBuffer) == configuredPixelSize.height
        else { return }
        handler(CapturedFrame(
            pixelBuffer: pixelBuffer,
            captureTimeNanos: WindowCaptureSession.displayTime(of: sampleBuffer),
            deliveredTimeNanos: HostClock.nowNanos(),
            pointSize: CGSize(width: CGFloat(configuredPixelSize.width) / scale,
                              height: CGFloat(configuredPixelSize.height) / scale),
            scale: scale
        ))
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.error("display capture stopped: \(error.localizedDescription, privacy: .public)")
        onStop?(error)
    }
}
