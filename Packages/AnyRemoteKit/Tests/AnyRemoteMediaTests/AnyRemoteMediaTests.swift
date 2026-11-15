import AnyRemoteWire
import CoreVideo
import Foundation
import Testing
@testable import AnyRemoteMedia

@Suite struct CaptureGeometryTests {
    @Test func unscaledWindowKeepsContentSize() {
        let size = WindowCaptureSession.windowPointSize(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 532), contentScale: 1)
        #expect(size == CGSize(width: 600, height: 532))
    }

    /// Observed on macOS 27: a 600×532 window grown to 700×560 is reported as
    /// contentRect 600×480 at contentScale 0.857 until the stream is reconfigured.
    @Test func grownWindowIsRecoveredFromContentScale() {
        let size = WindowCaptureSession.windowPointSize(
            contentRect: CGRect(x: 0, y: 0, width: 600.0000059604645, height: 480.0000047683716),
            contentScale: 0.8571428656578064)
        let pixels = WindowCaptureSession.pixelSize(points: size, scale: 2)
        #expect(pixels == (1400, 1120))
    }

    @Test func pixelSizeIsEven() {
        #expect(WindowCaptureSession.pixelSize(points: CGSize(width: 100.75, height: 50.25), scale: 2) == (202, 100))
        #expect(WindowCaptureSession.pixelSize(points: CGSize(width: 333, height: 201), scale: 1) == (332, 200))
    }
}

/// Real VideoToolbox round trip. Guards the property that makes text sharp:
/// chroma survives at full resolution (HEVC RExt 4:4:4), which 4:2:0 would
/// average away.
@Suite(.serialized) struct HEVCRoundTripTests {
    private static let width = 640
    private static let height = 360

    private static func makeAlternatingChromaFrame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        #expect(CVPixelBufferCreate(nil, width, height, WindowCaptureSession.pixelFormat, attributes, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(frame, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 1)
        for y in 0..<height {
            for x in 0..<width {
                luma[y * lumaStride + x] = 128
                // Cb/Cr alternate every column: red/blue stripes one pixel wide.
                let high: UInt8 = 200, low: UInt8 = 56
                chroma[y * chromaStride + x * 2] = x.isMultiple(of: 2) ? high : low
                chroma[y * chromaStride + x * 2 + 1] = x.isMultiple(of: 2) ? low : high
            }
        }
        return frame
    }

    @Test func preservesFullResolutionChroma() async throws {
        let source = try Self.makeAlternatingChromaFrame()
        let decoded = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DecodedFrame, Error>) in
            let once = Once()
            let decoder = HEVCDecoder { frame in
                if once.claim() { continuation.resume(returning: frame) }
            }
            let encoder = HEVCEncoder(configuration: .init(averageBitRate: 80_000_000)) { output in
                // Exercise the wire format too.
                guard let bytes = try? output.frame.serialized(),
                      let parsed = try? EncodedVideoFrame(serialized: bytes) else { return }
                decoder.decode(parsed, receivedTimeNanos: HostClock.nowNanos())
            }
            let now = HostClock.nowNanos()
            for index in 0..<3 {
                encoder.encode(CapturedFrame(
                    pixelBuffer: source, captureTimeNanos: now + UInt64(index) * 16_000_000,
                    deliveredTimeNanos: now, pointSize: CGSize(width: Self.width / 2, height: Self.height / 2), scale: 2))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if once.claim() { continuation.resume(throwing: CancellationError()) }
                withExtendedLifetime((encoder, decoder)) {}
            }
        }

        #expect(CVPixelBufferGetPixelFormatType(decoded.pixelBuffer) == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange)
        #expect(decoded.pixelWidth == Self.width)
        #expect(decoded.pixelHeight == Self.height)
        #expect(decoded.scale == 2)

        CVPixelBufferLockBaseAddress(decoded.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(decoded.pixelBuffer, .readOnly) }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(decoded.pixelBuffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(decoded.pixelBuffer, 1)
        // Mean absolute Cb difference between neighbouring columns. 4:4:4
        // keeps the ~144-level stripes; 4:2:0 subsampling flattens them to ~0.
        var total = 0
        var samples = 0
        for y in stride(from: 8, to: Self.height - 8, by: 8) {
            for x in stride(from: 8, to: Self.width - 8, by: 2) {
                total += abs(Int(chroma[y * rowBytes + x * 2]) - Int(chroma[y * rowBytes + (x + 1) * 2]))
                samples += 1
            }
        }
        let meanDifference = Double(total) / Double(samples)
        #expect(meanDifference > 100, "chroma stripes lost: mean neighbour difference \(meanDifference)")
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Child windows (menus, popovers) are sent as HEVC with an alpha layer so
/// their rounded, translucent edges composite over the viewer's desktop.
@Suite(.serialized) struct HEVCAlphaRoundTripTests {
    private static let width = 320
    private static let height = 192

    /// Left half fully transparent, right half opaque red (premultiplied BGRA).
    private static func makeHalfTransparentFrame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(frame)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * stride + x * 4
                let opaque = x >= width / 2
                pixel[0] = 0; pixel[1] = 0
                pixel[2] = opaque ? 255 : 0
                pixel[3] = opaque ? 255 : 0
            }
        }
        return frame
    }

    @Test func preservesAlpha() async throws {
        let source = try Self.makeHalfTransparentFrame()
        let decoded = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DecodedFrame, Error>) in
            let once = Once()
            let decoder = HEVCDecoder { frame in
                if once.claim() { continuation.resume(returning: frame) }
            }
            let encoder = HEVCEncoder(configuration: .init(averageBitRate: 12_000_000, alpha: true)) { output in
                #expect(output.frame.hasAlpha)
                guard let bytes = try? output.frame.serialized(),
                      let parsed = try? EncodedVideoFrame(serialized: bytes) else { return }
                decoder.decode(parsed, receivedTimeNanos: HostClock.nowNanos())
            }
            let now = HostClock.nowNanos()
            for index in 0..<3 {
                encoder.encode(CapturedFrame(
                    pixelBuffer: source, captureTimeNanos: now + UInt64(index) * 16_000_000,
                    deliveredTimeNanos: now, pointSize: CGSize(width: Self.width / 2, height: Self.height / 2), scale: 2))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if once.claim() { continuation.resume(throwing: CancellationError()) }
                withExtendedLifetime((encoder, decoder)) {}
            }
        }
        #expect(decoded.hasAlpha)
        #expect(CVPixelBufferGetPixelFormatType(decoded.pixelBuffer) == kCVPixelFormatType_32BGRA)
        let buffer = decoded.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        func pixel(_ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
            let p = base + y * stride + x * 4
            return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
        }
        let clear = pixel(Self.width / 4, Self.height / 2)
        let red = pixel(Self.width * 3 / 4, Self.height / 2)
        #expect(clear.a <= 8, "transparent half came back with alpha \(clear.a)")
        #expect(red.a >= 247, "opaque half came back with alpha \(red.a)")
        #expect(red.r >= 230 && red.g <= 30 && red.b <= 30, "opaque half color \(red)")
    }
}
