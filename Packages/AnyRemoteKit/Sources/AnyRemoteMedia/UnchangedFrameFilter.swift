import CoreVideo
import Foundation
import IOSurface

/// Holds back captured window frames that show nothing new.
///
/// ScreenCaptureKit (macOS 27) hands over a complete frame of every captured
/// window, its whole area marked dirty, whenever anything on the host's
/// screen changes: a still window streams at the full frame rate while
/// another one scrolls. Measured with six 2400×1600 windows, one scrolling:
/// each still window cost ~8 Mbps and a full encode, the encoder took 17 ms
/// a frame instead of 6, and the scrolling window reached the viewer 25 ms
/// after its capture instead of 8. Comparing a frame with the previous one
/// takes about 1 ms when they are the same, and stops at the first
/// difference otherwise.
///
/// Unchanged frames still pass for a moment after the last change: the
/// encoder sharpens a picture that stopped moving over the next ~30 frames
/// (text after a scroll), and the frames following the last change let the
/// viewer notice when that one was lost. They also pass while a keyframe is
/// due, so a viewer that asked for one gets it.
///
/// A window that has stood still for a second is only looked at every third
/// frame: comparing five still windows' every frame took 13% of a core on
/// the host. Their first change then reaches the viewer up to two frames
/// later.
final class UnchangedFrameFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: CVPixelBuffer?
    private var lastChangeNanos: UInt64 = 0
    /// Frames let go unlooked-at since the last comparison.
    private var passedOver = 0

    static let settleNanos: UInt64 = 500_000_000
    static let idleNanos: UInt64 = 1_000_000_000
    static let idleComparisonInterval = 3

    deinit { release() }

    /// Thread-safe. Whether `frame` should be encoded.
    func admits(_ frame: CapturedFrame, keyframeDue: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let buffer = frame.pixelBuffer
        if keyframeDue { return true }
        if let previous, previous !== buffer, frame.deliveredTimeNanos &- lastChangeNanos >= Self.idleNanos,
           passedOver < Self.idleComparisonInterval - 1 {
            passedOver += 1
            return false
        }
        passedOver = 0
        // The same buffer again was changed in place on purpose (the
        // sharing indicator painted over once its place was known).
        let unchanged = previous.map { $0 !== buffer && Self.samePixels($0, buffer) } ?? false
        if !unchanged {
            lastChangeNanos = frame.deliveredTimeNanos
            if previous !== buffer {
                release()
                // Keeps ScreenCaptureKit from drawing a later frame into it.
                if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
                    IOSurfaceIncrementUseCount(surface)
                }
                previous = buffer
            }
        }
        return !unchanged || frame.deliveredTimeNanos &- lastChangeNanos < Self.settleNanos
    }

    private func release() {
        if let previous, let surface = CVPixelBufferGetIOSurface(previous)?.takeUnretainedValue() {
            IOSurfaceDecrementUseCount(surface)
        }
        previous = nil
    }

    /// Byte for byte, row padding included: padding that differs only costs
    /// an encode, never a change left out.
    static func samePixels(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b),
              CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b),
              CVPixelBufferGetPixelFormatType(a) == CVPixelBufferGetPixelFormatType(b),
              CVPixelBufferGetPlaneCount(a) == CVPixelBufferGetPlaneCount(b) else { return false }
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
        }
        let planes = CVPixelBufferGetPlaneCount(a)
        for plane in 0..<max(planes, 1) {
            let (baseA, baseB, rowA, rowB, height): (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int, Int, Int)
            if planes == 0 {
                (baseA, baseB) = (CVPixelBufferGetBaseAddress(a), CVPixelBufferGetBaseAddress(b))
                (rowA, rowB) = (CVPixelBufferGetBytesPerRow(a), CVPixelBufferGetBytesPerRow(b))
                height = CVPixelBufferGetHeight(a)
            } else {
                (baseA, baseB) = (CVPixelBufferGetBaseAddressOfPlane(a, plane), CVPixelBufferGetBaseAddressOfPlane(b, plane))
                (rowA, rowB) = (CVPixelBufferGetBytesPerRowOfPlane(a, plane), CVPixelBufferGetBytesPerRowOfPlane(b, plane))
                height = CVPixelBufferGetHeightOfPlane(a, plane)
            }
            guard let baseA, let baseB, rowA == rowB else { return false }
            if memcmp(baseA, baseB, rowA * height) != 0 { return false }
        }
        return true
    }
}
