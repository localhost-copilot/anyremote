import AnyRemoteWire
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import VideoToolbox

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Decoder")

public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let sequence: UInt32
    /// The host's display time for the frame (see `EncodedVideoFrame`).
    public let captureTimeNanos: UInt64
    /// When the host was handed the frame, in the sender clock.
    public var handedOverTimeNanos: UInt64 = 0
    /// Set for one strip of a larger picture.
    public var tile: EncodedVideoFrame.Tile?
    /// Receiver clock domain.
    public let receivedTimeNanos: UInt64
    public let decodedTimeNanos: UInt64
    public let scale: UInt8
    /// BGRA with premultiplied alpha instead of `444f`.
    public let hasAlpha: Bool
    public var pixelWidth: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var pixelHeight: Int { CVPixelBufferGetHeight(pixelBuffer) }
}

/// Hardware HEVC decoder producing `444f` IOSurface-backed buffers for Metal,
/// or premultiplied BGRA for streams with an alpha layer.
///
/// A parameter-set change replaces only the decompression session.
public final class HEVCDecoder: @unchecked Sendable {
    public static let outputPixelFormat = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange

    private let output: @Sendable (DecodedFrame) -> Void
    /// Called when the decoder cannot continue without a new IDR.
    public var onNeedsKeyframe: (@Sendable () -> Void)?

    // Caller-serialized.
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var currentParameterSets: [Data] = []
    private var currentAlpha = false

    public init(output: @escaping @Sendable (DecodedFrame) -> Void) {
        self.output = output
    }

    deinit { invalidate() }

    public func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
        currentParameterSets = []
    }

    /// Must be called serially, in decode order.
    /// Returns false when the frame was not submitted.
    @discardableResult
    public func decode(_ frame: EncodedVideoFrame, receivedTimeNanos: UInt64) -> Bool {
        if !frame.parameterSets.isEmpty,
           frame.parameterSets != currentParameterSets || frame.hasAlpha != currentAlpha || session == nil {
            guard replaceSession(parameterSets: frame.parameterSets, alpha: frame.hasAlpha) else {
                onNeedsKeyframe?()
                return false
            }
        }
        guard let session, let format else { return false }
        guard let sampleBuffer = Self.makeSampleBuffer(frame.lengthPrefixedNALUnits, format: format) else {
            return false
        }

        let sequence = frame.sequence
        let captureTime = frame.captureTimeNanos
        let handedOver = frame.handedOverTimeNanos
        let tile = frame.tile
        let scale = frame.scale
        let hasAlpha = frame.hasAlpha
        // No `_1xRealTimePlayback`: it lets VT clock the decoder down to just
        // meet playback rate, which measured ~20% slower per frame.
        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: flags, infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer else {
                log.error("decode failed: \(status)")
                self.onNeedsKeyframe?()
                return
            }
            var decoded = DecodedFrame(
                pixelBuffer: imageBuffer,
                sequence: sequence,
                captureTimeNanos: captureTime,
                receivedTimeNanos: receivedTimeNanos,
                decodedTimeNanos: HostClock.nowNanos(),
                scale: scale,
                hasAlpha: hasAlpha
            )
            decoded.handedOverTimeNanos = handedOver
            decoded.tile = tile
            self.output(decoded)
        }
        if status != noErr {
            log.error("decode submit failed: \(status)")
            if status == kVTInvalidSessionErr { invalidate() }
            onNeedsKeyframe?()
            return false
        }
        return true
    }

    private func replaceSession(parameterSets: [Data], alpha: Bool) -> Bool {
        invalidate()
        guard let newFormat = Self.makeFormat(parameterSets, alpha: alpha) else {
            log.error("invalid parameter sets")
            return false
        }
        let destination: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: alpha ? kCVPixelFormatType_32BGRA : Self.outputPixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: newFormat,
            decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: destination as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else {
            log.error("VTDecompressionSessionCreate failed: \(status)")
            return false
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        format = newFormat
        currentParameterSets = parameterSets
        currentAlpha = alpha
        let dimensions = CMVideoFormatDescriptionGetDimensions(newFormat)
        log.info("decoder session \(dimensions.width)x\(dimensions.height)")
        return true
    }

    static func makeFormat(_ parameterSets: [Data], alpha: Bool = false) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        // The alpha layer's parameter sets travel with the base layer's; the
        // decoder only decodes it when the format says the stream has one.
        let extensions: CFDictionary? = alpha ? [
            kCMFormatDescriptionExtension_ContainsAlphaChannel: true,
            kCMFormatDescriptionExtension_AlphaChannelMode: kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha,
        ] as CFDictionary : nil
        let status: OSStatus = withUnsafePointers(to: parameterSets) { pointers, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: extensions,
                formatDescriptionOut: &format
            )
        }
        return status == noErr ? format : nil
    }

    private static func withUnsafePointers<R>(
        to sets: [Data],
        _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R
    ) -> R {
        let storage = sets.map { [UInt8]($0) }
        let buffers = storage.map { bytes -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(bytes.count, 1))
            pointer.initialize(from: bytes, count: bytes.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = storage.map(\.count)
        return pointers.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) }
        }
    }

    static func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        guard !data.isEmpty else { return nil }
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var sampleBuffer: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }
}
