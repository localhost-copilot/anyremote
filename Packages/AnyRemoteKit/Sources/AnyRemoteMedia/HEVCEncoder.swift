import AnyRemoteWire
import CoreMedia
import Foundation
import OSLog
import VideoToolbox

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Encoder")

/// Low-latency HEVC encoder for one window stream (or one strip of a display, see `TiledEncoder`).
///
/// Feeding `444f` buffers makes the Apple Silicon hardware encoder emit HEVC
/// RExt 4:4:4 (profile_idc 4). Do not enable
/// `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`: on macOS 27 it
/// selects a path that silently downgrades to 4:2:0.
///
/// `RealTime` stays off and speed is put before quality. In real-time mode
/// VT runs the engine just fast enough for the expected rate, so every frame
/// took ~9–12 ms however small: a 3840×528 strip 11.6 ms, the same as a
/// whole 4K frame. Without it, time follows the pixels. Measured on M6:
/// strip 11.6 → 3.7 ms, four strips at once 8.7 → 7.8 ms, 4K frame
/// 9.9 → 8.7 ms with PSNR 45.4 → 46.4 dB (about 13% more bits than asked
/// for). `RealTime` off alone encodes best (53.5 dB) but slowest (14.5 ms).
public final class HEVCEncoder: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var averageBitRate: Int
        /// Capture cadence.
        public var expectedFrameRate: Int
        /// Frame rate VideoToolbox is told to sustain. In real-time mode VT
        /// lowers encoder clocks until a frame takes about 1/rate, so this is
        /// effectively a per-frame latency budget, not a throughput hint.
        public var encoderPacingFrameRate: Int
        /// VideoToolbox real-time mode (off: see the type's notes).
        public var realTime: Bool
        /// HEVC with a premultiplied alpha layer from BGRA input (4:2:0).
        /// Used for child windows (menus, popovers) whose corners are clear.
        public var alpha: Bool

        public init(averageBitRate: Int = 40_000_000, expectedFrameRate: Int = 60,
                    encoderPacingFrameRate: Int = 120, realTime: Bool = false, alpha: Bool = false) {
            self.averageBitRate = averageBitRate
            self.expectedFrameRate = expectedFrameRate
            self.encoderPacingFrameRate = encoderPacingFrameRate
            self.realTime = realTime
            self.alpha = alpha
        }
    }

    public struct Output: Sendable {
        public let frame: EncodedVideoFrame
        public let capturedTimeNanos: UInt64
        public let deliveredTimeNanos: UInt64
        public let submittedTimeNanos: UInt64
        public let encodedTimeNanos: UInt64
    }

    private let configuration: Configuration
    private let output: @Sendable (Output) -> Void
    /// Owns the session and admission state. Encoder output also hops here,
    /// so no lock is needed and VT is never re-entered from its own callback.
    private let queue = DispatchQueue(label: "anyremote.encode", qos: .userInteractive)
    private let keyframeLock = NSLock()
    private var keyframeRequested = true

    // Queue-confined.
    private var session: VTCompressionSession?
    private var sessionSize: (width: Int, height: Int) = (0, 0)
    private var inFlight = false
    private var pending: CapturedFrame?
    private var nextSequence: UInt32 = 0
    private var averageBitRate: Int

    public init(configuration: Configuration = .init(), output: @escaping @Sendable (Output) -> Void) {
        self.configuration = configuration
        self.averageBitRate = configuration.averageBitRate
        self.output = output
    }

    /// Thread-safe. Applies to the running session and later ones.
    public func setAverageBitRate(_ bitRate: Int) {
        queue.async { [self] in
            guard bitRate != averageBitRate else { return }
            averageBitRate = bitRate
            if let session {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                     value: bitRate as CFNumber)
            }
        }
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    /// Thread-safe. The next submitted frame is encoded as an IDR.
    public func requestKeyframe() {
        keyframeLock.lock()
        keyframeRequested = true
        keyframeLock.unlock()
    }

    private func takeKeyframeRequest() -> Bool {
        keyframeLock.lock()
        defer { keyframeLock.unlock() }
        let requested = keyframeRequested
        keyframeRequested = false
        return requested
    }

    /// Thread-safe. Waits for the in-flight frame and releases the session.
    public func invalidate() {
        queue.sync {
            pending = nil
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
            inFlight = false
        }
    }

    /// Thread-safe. Latest wins: while a frame is encoding, newer captures
    /// replace each other instead of queueing. Queueing behind a busy
    /// hardware encoder adds a whole frame interval of latency per frame.
    public func encode(_ captured: CapturedFrame) {
        queue.async { [self] in
            if inFlight {
                pending = captured
            } else {
                submit(captured)
            }
        }
    }

    private func completeInFlight() {
        dispatchPrecondition(condition: .onQueue(queue))
        inFlight = false
        if let next = pending {
            pending = nil
            submit(next)
        }
    }

    private func submit(_ captured: CapturedFrame) {
        let width = CVPixelBufferGetWidth(captured.pixelBuffer)
        let height = CVPixelBufferGetHeight(captured.pixelBuffer)
        guard width <= Int(UInt16.max), height <= Int(UInt16.max) else { return }
        if session == nil || sessionSize != (width, height) {
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
            guard let created = makeSession(width: width, height: height) else { return }
            session = created
            sessionSize = (width, height)
            requestKeyframe()
        }
        guard let session else { return }

        let properties: CFDictionary? = takeKeyframeRequest()
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil
        let scale = UInt8(clamping: Int(captured.scale.rounded()))
        let pts = CMTime(value: CMTimeValue(captured.captureTimeNanos), timescale: 1_000_000_000)

        inFlight = true
        let submittedTime = HostClock.nowNanos()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: captured.pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            let encodedTime = HostClock.nowNanos()
            guard let self else { return }
            let box = SampleBufferBox(buffer: sampleBuffer)
            self.queue.async {
                defer { self.completeInFlight() }
                guard status == noErr else {
                    log.error("encode failed: \(status)")
                    self.requestKeyframe()
                    return
                }
                // A nil buffer with noErr is an encoder-side drop; references stay valid.
                guard let sampleBuffer = box.buffer else { return }
                self.emit(sampleBuffer, captured: captured, width: width, height: height,
                          scale: scale, submittedTime: submittedTime, encodedTime: encodedTime)
            }
        }
        if status != noErr {
            log.error("encode submit failed: \(status)")
            requestKeyframe()
            inFlight = false
        }
    }

    private func makeSession(width: Int, height: Int) -> VTCompressionSession? {
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: configuration.alpha ? kCMVideoCodecType_HEVCWithAlpha : kCMVideoCodecType_HEVC,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            log.error("VTCompressionSessionCreate failed: \(status)")
            return nil
        }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: configuration.realTime,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: !configuration.realTime,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: averageBitRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: configuration.encoderPacingFrameRate,
            // Keyframes are produced on demand (start, resize, loss).
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int32.max,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 0,
            // No color tagging properties: each one adds ~2.5 ms per 4K frame
            // (measured on M6). The capture buffers' attachments are used.
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(created, key: key, value: value as CFTypeRef)
            if result != noErr { log.info("encoder property \(key as String, privacy: .public) unsupported: \(result)") }
        }
        VTCompressionSessionPrepareToEncodeFrames(created)
        log.info("encoder session \(width)x\(height)")
        return created
    }

    private func emit(
        _ sampleBuffer: CMSampleBuffer, captured: CapturedFrame, width: Int, height: Int,
        scale: UInt8, submittedTime: UInt64, encodedTime: UInt64
    ) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let isKeyframe = Self.isKeyframe(sampleBuffer)

        var parameterSets: [Data] = []
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = Self.parameterSets(of: format)
        }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        var payload = Data(count: length)
        let copyStatus = payload.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copyStatus == noErr else { return }

        let sequence = nextSequence
        nextSequence &+= 1

        output(Output(
            frame: EncodedVideoFrame(
                sequence: sequence,
                captureTimeNanos: captured.captureTimeNanos,
                flags: EncodedVideoFrame.Flags(isKeyframe ? [.keyframe] : [])
                    .union(configuration.alpha ? [.alpha] : []),
                pixelWidth: UInt16(width),
                pixelHeight: UInt16(height),
                scale: scale,
                parameterSets: parameterSets,
                lengthPrefixedNALUnits: payload,
                captureLeadMicros: UInt16(clamping: (captured.captureTimeNanos
                    - min(captured.captureTimeNanos, captured.deliveredTimeNanos)) / 1000),
                tile: captured.tile
            ),
            capturedTimeNanos: captured.captureTimeNanos,
            deliveredTimeNanos: captured.deliveredTimeNanos,
            submittedTimeNanos: submittedTime,
            encodedTimeNanos: encodedTime
        ))
    }

    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first else { return true }
        return !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    static func parameterSets(of format: CMFormatDescription) -> [Data] {
        var count = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        ) == noErr else { return [] }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return sets
    }
}

private struct SampleBufferBox: @unchecked Sendable {
    let buffer: CMSampleBuffer?
}
