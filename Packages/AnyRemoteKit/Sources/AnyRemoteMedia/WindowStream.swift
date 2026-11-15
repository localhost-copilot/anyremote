import AnyRemoteWire
import Foundation
import OSLog
import ScreenCaptureKit

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Stream")

/// Host side of one stream (a window, or a whole display): capture → encode → datagrams.
public final class WindowStreamSender: @unchecked Sendable {
    public let streamID: UInt16
    public let stats: PipelineStats
    private var capture: (any FrameCapturing)!
    /// One session for the whole picture, or one per strip.
    private enum Encoding {
        case whole(HEVCEncoder)
        case strips(TiledEncoder)
    }
    private let encoding: Encoding

    /// Called on the capture queue when SCK stops the stream on its own
    /// (window closed, display gone, permission revoked).
    public var onStop: (@Sendable (Error?) -> Void)? {
        get { capture.onStop }
        set { capture.onStop = newValue }
    }

    public convenience init(
        window: SCWindow,
        streamID: UInt16,
        configuration: HEVCEncoder.Configuration = .init(),
        maximumDatagramSize: Int = 1200,
        stats: PipelineStats = PipelineStats(),
        send: @escaping @Sendable ([Data]) -> Void
    ) {
        self.init(streamID: streamID, configuration: configuration, maximumDatagramSize: maximumDatagramSize,
                  stats: stats, send: send) { encode in
            WindowCaptureSession(window: window, frameRate: configuration.expectedFrameRate,
                                 alpha: configuration.alpha, handler: encode)
        }
    }

    /// A whole display.
    /// - Parameter tileStreamIDs: with more than one, the display is sent as
    ///   that many horizontal strips, each under its own stream ID (the
    ///   first should be `streamID`).
    public convenience init(
        displayID: CGDirectDisplayID,
        excludingProcessID: pid_t? = nil,
        exceptingWindowIDs: Set<CGWindowID> = [],
        streamID: UInt16,
        tileStreamIDs: [UInt16]? = nil,
        configuration: HEVCEncoder.Configuration = .init(),
        maximumDatagramSize: Int = 1200,
        stats: PipelineStats = PipelineStats(),
        send: @escaping @Sendable ([Data]) -> Void
    ) {
        self.init(streamID: streamID, tileStreamIDs: tileStreamIDs, configuration: configuration,
                  maximumDatagramSize: maximumDatagramSize, stats: stats, send: send) { encode in
            DisplayCaptureSession(displayID: displayID, frameRate: configuration.expectedFrameRate,
                                  excludingProcessID: excludingProcessID,
                                  exceptingWindowIDs: exceptingWindowIDs, handler: encode)
        }
    }

    private init(
        streamID: UInt16,
        tileStreamIDs: [UInt16]? = nil,
        configuration: HEVCEncoder.Configuration,
        maximumDatagramSize: Int,
        stats: PipelineStats,
        send: @escaping @Sendable ([Data]) -> Void,
        makeCapture: (@escaping @Sendable (CapturedFrame) -> Void) -> any FrameCapturing
    ) {
        self.streamID = streamID
        self.stats = stats
        let emit: @Sendable (UInt16, HEVCEncoder.Output) -> Void = { streamID, output in
            stats.record(.capture, from: output.deliveredTimeNanos, to: output.capturedTimeNanos)
            stats.record(.encodeWait, from: output.deliveredTimeNanos, to: output.submittedTimeNanos)
            stats.record(.encode, from: output.submittedTimeNanos, to: output.encodedTimeNanos)
            do {
                let frame = output.frame
                let bytes = try frame.serialized()
                stats.recordFrame(bytes: bytes.count, keyframe: frame.isKeyframe, width: Int(frame.pixelWidth),
                                  height: Int(frame.tile?.canvasHeight ?? frame.pixelHeight),
                                  countsFrame: frame.tile?.isFirstOfFrame ?? true)
                send(try VideoFragmenter.fragment(bytes, streamID: streamID,
                                                  frameSequence: frame.sequence,
                                                  maximumDatagramSize: maximumDatagramSize))
            } catch {
                log.error("frame framing failed: \(String(describing: error), privacy: .public)")
            }
        }
        if let tileStreamIDs, tileStreamIDs.count > 1,
           let tiled = TiledEncoder(streamIDs: tileStreamIDs, configuration: configuration, output: emit) {
            encoding = .strips(tiled)
            capture = makeCapture { frame in tiled.encode(frame) }
        } else {
            let encoder = HEVCEncoder(configuration: configuration) { emit(streamID, $0) }
            encoding = .whole(encoder)
            capture = makeCapture { frame in encoder.encode(frame) }
        }
    }

    public func start() async throws { try await capture.start() }

    public func stop() async {
        await capture.stop()
        switch encoding {
        case let .whole(encoder): encoder.invalidate()
        case let .strips(tiled): tiled.invalidate()
        }
    }

    /// Strips: the one sent under `streamID` (all of them when nil), sent again right away.
    public func requestKeyframe(streamID: UInt16? = nil) {
        switch encoding {
        case let .whole(encoder): encoder.requestKeyframe()
        case let .strips(tiled): tiled.requestKeyframe(streamID: streamID)
        }
    }

    /// The window's current frame (global points), for captures that crop it from its display.
    public func windowFrameChanged(_ frame: CGRect) {
        (capture as? WindowCaptureSession)?.windowFrameChanged(frame)
    }

    /// The display's new size (points) and scale, for display streams.
    public func displayChanged(pointSize: CGSize, scale: CGFloat) {
        (capture as? DisplayCaptureSession)?.displayChanged(pointSize: pointSize, scale: scale)
    }

    /// Display streams: captures another display from now on.
    public func switchDisplay(to displayID: CGDirectDisplayID) async throws {
        guard let capture = capture as? DisplayCaptureSession else { return }
        try await capture.switchDisplay(to: displayID)
        requestKeyframe()
    }

    /// Strips share it.
    public func setAverageBitRate(_ bitRate: Int) {
        switch encoding {
        case let .whole(encoder): encoder.setAverageBitRate(bitRate)
        case let .strips(tiled): tiled.setAverageBitRate(bitRate)
        }
    }
}

/// Viewer side of one window stream: datagrams → reassembly → decode.
public final class WindowStreamReceiver: @unchecked Sendable {
    public struct Report: Sendable {
        public var framesReceived: UInt32
        public var framesDropped: UInt32
    }

    public let streamID: UInt16
    public let stats: PipelineStats
    private let queue = DispatchQueue(label: "anyremote.receive", qos: .userInteractive)
    private let onKeyframeRequest: @Sendable () -> Void
    private var decoder: HEVCDecoder!

    // Queue-confined.
    private var reassembler: VideoReassembler
    private var gate = KeyframeGate()
    private var lastKeyframeRequestNanos: UInt64 = 0
    private var report = Report(framesReceived: 0, framesDropped: 0)
    private static let keyframeRequestInterval: UInt64 = 100_000_000

    /// Maps sender capture times into this clock for the `receive` stage.
    public var remoteClock: RemoteClock?
    /// Count frames and bytes in `stats` (off when sharing stats with an in-process sender).
    public var recordsFrames = true

    public init(
        streamID: UInt16,
        stats: PipelineStats = PipelineStats(),
        onFrame: @escaping @Sendable (DecodedFrame) -> Void,
        onKeyframeRequest: @escaping @Sendable () -> Void
    ) {
        self.streamID = streamID
        self.stats = stats
        self.reassembler = VideoReassembler(streamID: streamID)
        self.onKeyframeRequest = onKeyframeRequest
        self.decoder = HEVCDecoder { frame in
            stats.record(.decode, from: frame.receivedTimeNanos, to: frame.decodedTimeNanos)
            onFrame(frame)
        }
        decoder.onNeedsKeyframe = { [weak self] in
            guard let self else { return }
            self.queue.async { self.handleLoss() }
        }
    }

    public func receive(_ datagrams: [Data]) {
        queue.async { [self] in
            for datagram in datagrams { process(datagram) }
        }
    }

    public func close() {
        queue.sync { decoder.invalidate() }
    }

    /// Counts since the previous call.
    public func takeReport() -> Report {
        queue.sync {
            let current = report
            report = Report(framesReceived: 0, framesDropped: 0)
            return current
        }
    }

    private func process(_ datagram: Data) {
        let output: VideoReassembler.Output
        do {
            output = try reassembler.accept(datagram)
        } catch {
            return
        }
        if output.droppedFrameCount > 0 {
            stats.recordDropped(Int(output.droppedFrameCount))
            report.framesDropped &+= output.droppedFrameCount
            handleLoss()
        }
        for (_, data) in output.frames {
            let received = HostClock.nowNanos()
            guard let frame = try? EncodedVideoFrame(serialized: data) else {
                handleLoss()
                continue
            }
            report.framesReceived &+= 1
            if recordsFrames {
                stats.recordFrame(bytes: data.count, keyframe: frame.isKeyframe, width: Int(frame.pixelWidth),
                                  height: Int(frame.tile?.canvasHeight ?? frame.pixelHeight),
                                  countsFrame: frame.tile?.isFirstOfFrame ?? true)
            }
            if let captured = remoteClock?.localTime(fromSender: frame.handedOverTimeNanos) {
                stats.record(.receive, from: captured, to: received)
            }
            guard gate.admit(isKeyframe: frame.isKeyframe) else {
                requestKeyframeIfDue()
                continue
            }
            if !decoder.decode(frame, receivedTimeNanos: received) {
                handleLoss()
            }
        }
    }

    private func handleLoss() {
        _ = gate.noteDropped()
        requestKeyframeIfDue()
    }

    private func requestKeyframeIfDue() {
        let now = HostClock.nowNanos()
        guard now - lastKeyframeRequestNanos >= Self.keyframeRequestInterval else { return }
        lastKeyframeRequestNanos = now
        onKeyframeRequest()
    }
}
