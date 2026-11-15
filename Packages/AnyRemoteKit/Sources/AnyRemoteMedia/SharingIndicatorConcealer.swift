import CoreGraphics
import CoreVideo

/// Paints over macOS's screen-sharing indicator in a captured window frame.
///
/// Since macOS 27 the window server draws a purple "being shared" capsule
/// over the close, minimize and zoom buttons of every window that is being
/// captured, and composites it into the capture itself (with every
/// ScreenCaptureKit filter tried: independent window, no child windows, a
/// display including only the window, a display excluding the capsule's
/// window). There is no API to turn it off. The viewer draws its own window
/// buttons at that spot, so the capsule is replaced here by the title bar
/// next to it: each row is filled with the pixel just right of it, which
/// reproduces flat title bars and their top-to-bottom gradients. (The left
/// side is no use: near the top it lies in the window's rounded corner,
/// outside the window.)
public enum SharingIndicatorConcealer {
    /// Fills `rect` (buffer pixels, top-left origin) in place. Supports the
    /// capture formats: 8-bit bi-planar 4:4:4 and BGRA. The caller must own
    /// the buffer until encoding (SCK's buffers are ours until released).
    public static func conceal(_ rect: CGRect, in pixelBuffer: CVPixelBuffer) {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planes: [(index: Int?, bytesPerPixel: Int)]
        switch format {
        case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
            planes = [(0, 1), (1, 2)]
        case kCVPixelFormatType_32BGRA:
            planes = [(nil, 4)]
        default:
            return
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in planes {
            let base: UnsafeMutableRawPointer?
            let width, height, bytesPerRow: Int
            if let index = plane.index {
                base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, index)
                width = CVPixelBufferGetWidthOfPlane(pixelBuffer, index)
                height = CVPixelBufferGetHeightOfPlane(pixelBuffer, index)
                bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index)
            } else {
                base = CVPixelBufferGetBaseAddress(pixelBuffer)
                width = CVPixelBufferGetWidth(pixelBuffer)
                height = CVPixelBufferGetHeight(pixelBuffer)
                bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            }
            guard let base else { continue }
            fill(rect, base: base.assumingMemoryBound(to: UInt8.self), width: width, height: height,
                 bytesPerRow: bytesPerRow, bytesPerPixel: plane.bytesPerPixel)
        }
    }

    static func fill(_ rect: CGRect, base: UnsafeMutablePointer<UInt8>, width: Int, height: Int,
                     bytesPerRow: Int, bytesPerPixel: Int) {
        let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }
        let x0 = Int(clipped.minX), x1 = Int(clipped.maxX), y0 = Int(clipped.minY), y1 = Int(clipped.maxY)
        // The column just right of the area; at the buffer's right edge, the one left of it.
        let source = x1 < width ? x1 : x0 - 1
        guard source >= 0 else { return }
        for y in y0..<y1 {
            let row = base + y * bytesPerRow
            let pixel = row + source * bytesPerPixel
            for x in x0..<x1 {
                (row + x * bytesPerPixel).update(from: pixel, count: bytesPerPixel)
            }
        }
    }
}
