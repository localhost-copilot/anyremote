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
    /// What captured frames go to: the encoder, which outlives a switch of window.
    private var encodeFrame: (@Sendable (CapturedFrame) -> Void)!
    /// Window streams: makes the capture of another window (see `switchWindow`).
    private var makeWindowCapture: ((SCWindow, Int) -> WindowCaptureSession)?
    /// Frames a second captured at most. Owner's queue, like `capture`.
    private var frameRate: Int

    /// Called on the capture queue when SCK stops the stream on its own
    /// (window closed, display gone, permission revoked).
    public var onStop: (@Sendable (Error?) -> Void)? {
        didSet { capture.onStop = onStop }
    }

    public convenience init(
        window: SCWindow,
        streamID: UInt16,
        configuration: HEVCEncoder.Configuration = .init(),
        maximumDatagramSize: Int = 1200,
        backdrop: Bool = false,
        stats: PipelineStats = PipelineStats(),
        send: @escaping @Sendable ([Data]) -> Void
    ) {
        self.init(streamID: streamID, configuration: configuration, maximumDatagramSize: maximumDatagramSize,
                  stats: stats, skipsUnchangedFrames: true, send: send) { encode in
            WindowCaptureSession(window: window, frameRate: configuration.expectedFrameRate,
                                 alpha: configuration.alpha, backdrop: backdrop, handler: encode)
        }
        let encode = encodeFrame!
        makeWindowCapture = { window, frameRate in
            WindowCaptureSession(window: window, frameRate: frameRate,
                                 alpha: configuration.alpha, backdrop: backdrop, handler: encode)
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
        skipsUnchangedFrames: Bool = false,
        send: @escaping @Sendable ([Data]) -> Void,
        makeCapture: (@escaping @Sendable (CapturedFrame) -> Void) -> any FrameCapturing
    ) {
        self.streamID = streamID
        self.stats = stats
        self.frameRate = configuration.expectedFrameRate
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
            encodeFrame = { frame in tiled.encode(frame) }
        } else {
            let encoder = HEVCEncoder(configuration: configuration) { emit(streamID, $0) }
            encoding = .whole(encoder)
            // Windows only: display captures know what changed and send
            // nothing when nothing did. Development: ANYREMOTE_UNCHANGED_FRAMES=1
            // sends them all, for comparisons.
            if skipsUnchangedFrames, ProcessInfo.processInfo.environment["ANYREMOTE_UNCHANGED_FRAMES"] != "1" {
                let filter = UnchangedFrameFilter()
                encodeFrame = { frame in
                    guard filter.admits(frame, keyframeDue: encoder.keyframeDue) else { return }
                    encoder.encode(frame)
                }
            } else {
                encodeFrame = { frame in encoder.encode(frame) }
            }
        }
        capture = makeCapture(encodeFrame)
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

    /// A viewer's request after loss: ignored while the last keyframe may
    /// still be on its way (`HEVCEncoder.requestRecoveryKeyframe`).
    public func requestRecoveryKeyframe(streamID: UInt16? = nil) {
        switch encoding {
        case let .whole(encoder): encoder.requestRecoveryKeyframe()
        case let .strips(tiled): tiled.requestKeyframe(streamID: streamID, recovery: true)
        }
    }

    /// The window's current frame (global points), for captures that crop it from its display.
    public func windowFrameChanged(_ frame: CGRect) {
        (capture as? WindowCaptureSession)?.windowFrameChanged(frame)
    }

    /// Window streams: where macOS draws its sharing indicator (window points
    /// from the top-left corner), painted over before encoding.
    public func setConcealedRect(_ rect: CGRect?) {
        (capture as? WindowCaptureSession)?.setConcealedRect(rect)
    }

    /// Window streams: captures `window` from now on, into the same encoder,
    /// so the viewer's picture goes on under the same stream (the tab that
    /// took the place of the window captured so far). The old capture stops
    /// first. Called on the owner's queue, like the other setters; `done`
    /// gets the new capture's start error, if any.
    public func switchWindow(to window: SCWindow, done: @escaping @Sendable (Error?) -> Void) {
        guard let makeWindowCapture else { return done(nil) }
        let old = capture!
        old.onStop = nil
        let new = makeWindowCapture(window, frameRate)
        new.onStop = onStop
        capture = new
        Task {
            await old.stop()
            do {
                try await new.start()
                requestKeyframe()
                done(nil)
            } catch {
                done(error)
            }
        }
    }

    /// Captures up to `frameRate` frames a second from now on (the viewer's
    /// choice, `ControlMessage.frameRate`). Called on the owner's queue.
    public func setFrameRate(_ frameRate: Int) {
        guard frameRate != self.frameRate else { return }
        self.frameRate = frameRate
        capture.setFrameRate(frameRate)
    }

    /// The captured window is going away for another (see `switchWindow`):
    /// its capture stopping (a closed tab) no longer ends the stream.
    public func ignoreCaptureStop() {
        capture.onStop = nil
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
        /// See `QueuingDelay`; nil when no frame arrived or clocks aren't synced.
        public var queuingMilliseconds: Double?
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
    private static let keyframeRequestInterval: UInt64 = 100_000_000

    /// Under `lock`: the report, so the client's queue takes it without
    /// waiting for this queue (a stuck receive queue stalled the client's
    /// queue with it, and with that every click sent to the host).
    private let lock = NSLock()
    private var report = Report(framesReceived: 0, framesDropped: 0)
    private var queuing = QueuingDelay()
    /// Under `lock`: progress, for `monitor`.
    private var progress = Progress()
    private var monitor: StallMonitor?

    private struct Progress {
        var lastDatagram: UInt64 = 0
        /// Set while a batch of datagrams is being processed.
        var busySince: UInt64?
        /// Set while the decoder takes a frame.
        var submittingSince: UInt64?
        var lastSubmitted: UInt64 = 0
        var lastDecoded: UInt64 = 0
        var awaitingKeyframeSince: UInt64?
        var keyframeRequests = 0
    }

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
        let decodedAt = DecodedAt()
        self.decoder = HEVCDecoder { frame in
            decodedAt.note(frame.decodedTimeNanos)
            stats.record(.decode, from: frame.receivedTimeNanos, to: frame.decodedTimeNanos)
            onFrame(frame)
        }
        decoder.onNeedsKeyframe = { [weak self] in
            guard let self else { return }
            self.queue.async { self.handleLoss() }
        }
        progress.awaitingKeyframeSince = HostClock.nowNanos()
        monitor = StallMonitor(name: "stream \(streamID)") { [weak self] in
            self?.stallDescription(decodedAt: decodedAt.value)
        }
    }

    public func receive(_ datagrams: [Data]) {
        lock.lock()
        progress.lastDatagram = HostClock.nowNanos()
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            progress.busySince = HostClock.nowNanos()
            lock.unlock()
            for datagram in datagrams { process(datagram) }
            lock.lock()
            progress.busySince = nil
            lock.unlock()
        }
    }

    public func close() {
        monitor?.cancel()
        queue.sync { decoder.invalidate() }
    }

    /// Counts since the previous call. Doesn't wait for the receive queue.
    public func takeReport() -> Report {
        lock.lock()
        defer { lock.unlock() }
        var current = report
        current.queuingMilliseconds = queuing.take()
        report = Report(framesReceived: 0, framesDropped: 0)
        return current
    }

    /// Monitor queue. What keeps pictures from coming out, if anything.
    private func stallDescription(decodedAt: UInt64) -> String? {
        let now = HostClock.nowNanos()
        lock.lock()
        let progress = progress
        lock.unlock()
        let since = { StallMonitor.seconds(since: $0, now: now) }
        let age = { StallMonitor.elapsed(since: $0, now: now) }
        if let start = progress.submittingSince, age(start) > 1_000_000_000 {
            return "the decoder has not taken a frame for \(since(start)); the receive queue waits for it"
        }
        if let start = progress.busySince, age(start) > 1_000_000_000 {
            return "the receive queue has been busy for \(since(start))"
        }
        // Only while the host sends: an unchanged screen sends nothing.
        guard age(progress.lastDatagram) < 1_000_000_000 else { return nil }
        if let start = progress.awaitingKeyframeSince, age(start) > 2_000_000_000 {
            return "waiting for a keyframe for \(since(start)) (\(progress.keyframeRequests) requested)"
        }
        let lastOutput = max(decodedAt, progress.lastDecoded)
        if progress.lastSubmitted > lastOutput, age(progress.lastSubmitted) < 1_000_000_000,
           age(max(lastOutput, progress.awaitingKeyframeSince ?? 0)) > 2_000_000_000 {
            return "frames go into the decoder but none came out "
                + (lastOutput > 0 ? "for \(since(lastOutput))" : "since the stream began")
        }
        return nil
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
            lock.lock()
            report.framesDropped &+= output.droppedFrameCount
            lock.unlock()
            handleLoss()
        }
        for (_, data) in output.frames {
            let received = HostClock.nowNanos()
            guard let frame = try? EncodedVideoFrame(serialized: data) else {
                handleLoss()
                continue
            }
            lock.lock()
            report.framesReceived &+= 1
            lock.unlock()
            if recordsFrames {
                stats.recordFrame(bytes: data.count, keyframe: frame.isKeyframe, width: Int(frame.pixelWidth),
                                  height: Int(frame.tile?.canvasHeight ?? frame.pixelHeight),
                                  countsFrame: frame.tile?.isFirstOfFrame ?? true)
            }
            if let captured = remoteClock?.localTime(fromSender: frame.handedOverTimeNanos) {
                stats.record(.receive, from: captured, to: received)
                lock.lock()
                queuing.record(transitMilliseconds: (Double(received) - Double(captured)) / 1e6)
                lock.unlock()
            }
            guard gate.admit(isKeyframe: frame.isKeyframe) else {
                requestKeyframeIfDue()
                continue
            }
            lock.lock()
            progress.awaitingKeyframeSince = nil
            progress.submittingSince = HostClock.nowNanos()
            lock.unlock()
            let submitted = decoder.decode(frame, receivedTimeNanos: received)
            lock.lock()
            progress.submittingSince = nil
            if submitted { progress.lastSubmitted = HostClock.nowNanos() }
            lock.unlock()
            if !submitted {
                handleLoss()
            }
        }
    }

    private func handleLoss() {
        if gate.noteDropped() {
            lock.lock()
            progress.awaitingKeyframeSince = HostClock.nowNanos()
            progress.keyframeRequests = 0
            lock.unlock()
        }
        requestKeyframeIfDue()
    }

    private func requestKeyframeIfDue() {
        let now = HostClock.nowNanos()
        guard now - lastKeyframeRequestNanos >= Self.keyframeRequestInterval else { return }
        lastKeyframeRequestNanos = now
        lock.lock()
        progress.keyframeRequests += 1
        lock.unlock()
        onKeyframeRequest()
    }
}

/// When the decoder last produced a picture; written from its output thread.
private final class DecodedAt: @unchecked Sendable {
    private let lock = NSLock()
    private var nanos: UInt64 = 0
    func note(_ value: UInt64) { lock.lock(); nanos = value; lock.unlock() }
    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return nanos }
}
