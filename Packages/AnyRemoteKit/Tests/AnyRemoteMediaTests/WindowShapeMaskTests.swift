import CoreGraphics
import CoreVideo
import Testing
@testable import AnyRemoteMedia

@Suite struct WindowShapeMaskTests {
    /// A window-alone capture: opaque inside a rounded rectangle, clear outside.
    private func shape(width: Int, height: Int, radius: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        return try #require(context.makeImage())
    }

    /// A display capture of the same area: opaque white everywhere.
    private func opaqueFrame(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        try #require(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 255, CVPixelBufferGetBytesPerRow(frame) * height)
        CVPixelBufferUnlockBaseAddress(frame, [])
        return frame
    }

    private func pixel(_ frame: CVPixelBuffer, x: Int, y: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(frame) + x * 4
        return Array(UnsafeBufferPointer(start: base + offset, count: 4))
    }

    @Test func cutsTheCornersOutsideTheShape() throws {
        let mask = try #require(WindowShapeMask(image: try shape(width: 60, height: 40, radius: 12)))
        let frame = try opaqueFrame(width: 60, height: 40)
        mask.apply(to: frame)
        // Premultiplied: every channel of a cut pixel goes to zero.
        for (x, y) in [(0, 0), (59, 0), (0, 39), (59, 39)] {
            #expect(pixel(frame, x: x, y: y) == [0, 0, 0, 0])
        }
        #expect(pixel(frame, x: 30, y: 20) == [255, 255, 255, 255])
        #expect(pixel(frame, x: 30, y: 0) == [255, 255, 255, 255])
        // The antialiased rim keeps part of the pixel, with matching color.
        let rim = (0..<12).map { pixel(frame, x: $0, y: $0) }.first { $0[3] > 0 && $0[3] < 255 }
        let partial = try #require(rim)
        #expect(partial[0] == partial[3])
    }

    @Test func leavesFramesOfAnotherSizeAlone() throws {
        let mask = try #require(WindowShapeMask(image: try shape(width: 60, height: 40, radius: 12)))
        let frame = try opaqueFrame(width: 62, height: 40)
        #expect(!mask.fits(frame))
        mask.apply(to: frame)
        #expect(pixel(frame, x: 0, y: 0) == [255, 255, 255, 255])
    }
}
