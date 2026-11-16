import CoreVideo
import Foundation
import Testing
@testable import AnyRemoteMedia

@Suite struct UnchangedFrameFilterTests {
    private static let format: OSType = 0x3434_3466 // '444f', what window captures deliver

    /// A 4:4:4 biplanar buffer filled with `value`, padding included, as
    /// two captures of the same picture are.
    private func makeBuffer(_ value: UInt8, width: Int = 64, height: Int = 16) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        try #require(CVPixelBufferCreate(nil, width, height, Self.format, attributes, &buffer) == kCVReturnSuccess)
        let made = try #require(buffer)
        CVPixelBufferLockBaseAddress(made, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(made) {
            memset(CVPixelBufferGetBaseAddressOfPlane(made, plane), Int32(value),
                   CVPixelBufferGetBytesPerRowOfPlane(made, plane) * CVPixelBufferGetHeightOfPlane(made, plane))
        }
        CVPixelBufferUnlockBaseAddress(made, [])
        return made
    }

    private func frame(_ buffer: CVPixelBuffer, at milliseconds: UInt64) -> CapturedFrame {
        CapturedFrame(pixelBuffer: buffer, captureTimeNanos: milliseconds * 1_000_000,
                      deliveredTimeNanos: milliseconds * 1_000_000, pointSize: CGSize(width: 32, height: 8), scale: 2)
    }

    @Test func comparesEveryPlane() throws {
        let a = try makeBuffer(7), b = try makeBuffer(7)
        #expect(UnchangedFrameFilter.samePixels(a, b))
        // One chroma byte in the last row.
        CVPixelBufferLockBaseAddress(b, [])
        let chroma = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt8.self)
        chroma[CVPixelBufferGetBytesPerRowOfPlane(b, 1) * (CVPixelBufferGetHeightOfPlane(b, 1) - 1) + 3] = 8
        CVPixelBufferUnlockBaseAddress(b, [])
        #expect(!UnchangedFrameFilter.samePixels(a, b))
        #expect(!UnchangedFrameFilter.samePixels(a, try makeBuffer(7, width: 66)))
    }

    @Test func holdsBackUnchangedFramesOnceSettled() throws {
        let filter = UnchangedFrameFilter()
        #expect(filter.admits(frame(try makeBuffer(1), at: 1000), keyframeDue: false))
        // The encoder still sharpens the picture for a moment.
        #expect(filter.admits(frame(try makeBuffer(1), at: 1100), keyframeDue: false))
        #expect(!filter.admits(frame(try makeBuffer(1), at: 1600), keyframeDue: false))
        // A viewer asked for a keyframe.
        #expect(filter.admits(frame(try makeBuffer(1), at: 1620), keyframeDue: true))
        #expect(filter.admits(frame(try makeBuffer(2), at: 1640), keyframeDue: false))
        #expect(filter.admits(frame(try makeBuffer(2), at: 1700), keyframeDue: false))
    }

    @Test func passesTheSameBufferChangedInPlace() throws {
        let filter = UnchangedFrameFilter()
        let buffer = try makeBuffer(1)
        #expect(filter.admits(frame(buffer, at: 1000), keyframeDue: false))
        #expect(!filter.admits(frame(try makeBuffer(1), at: 1600), keyframeDue: false))
        // The sharing indicator painted over in the frame kept so far.
        #expect(filter.admits(frame(buffer, at: 1700), keyframeDue: false))
    }

    @Test func looksAtAnIdleWindowEveryThirdFrame() throws {
        let filter = UnchangedFrameFilter()
        #expect(filter.admits(frame(try makeBuffer(1), at: 1000), keyframeDue: false))
        #expect(!filter.admits(frame(try makeBuffer(1), at: 2100), keyframeDue: false))
        // A change in a frame passed over shows in the next one looked at.
        #expect(!filter.admits(frame(try makeBuffer(2), at: 2116), keyframeDue: false))
        #expect(filter.admits(frame(try makeBuffer(2), at: 2133), keyframeDue: false))
        // Changed just now: every frame is looked at again.
        #expect(filter.admits(frame(try makeBuffer(3), at: 2150), keyframeDue: false))
        #expect(filter.admits(frame(try makeBuffer(3), at: 2166), keyframeDue: false))
    }
}
