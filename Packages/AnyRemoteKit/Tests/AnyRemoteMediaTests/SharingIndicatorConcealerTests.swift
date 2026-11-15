import CoreVideo
import Foundation
import Testing
@testable import AnyRemoteMedia

@Suite struct SharingIndicatorConcealerTests {
    private func makeBuffer(_ format: OSType, width: Int = 40, height: Int = 10) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(nil, width, height, format, attributes, &buffer)
        try #require(status == kCVReturnSuccess)
        return try #require(buffer)
    }

    /// Writes `value(x, plane)` into every byte of every pixel.
    private func paint(_ buffer: CVPixelBuffer, planes: [(Int?, Int)], value: (Int, Int) -> UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for (index, bytesPerPixel) in planes {
            let base = (index.map { CVPixelBufferGetBaseAddressOfPlane(buffer, $0) } ?? CVPixelBufferGetBaseAddress(buffer))!
                .assumingMemoryBound(to: UInt8.self)
            let rowBytes = index.map { CVPixelBufferGetBytesPerRowOfPlane(buffer, $0) } ?? CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<CVPixelBufferGetHeight(buffer) {
                for x in 0..<CVPixelBufferGetWidth(buffer) {
                    for byte in 0..<bytesPerPixel { base[y * rowBytes + x * bytesPerPixel + byte] = value(x, index ?? 0) }
                }
            }
        }
    }

    private func byte(_ buffer: CVPixelBuffer, plane: Int?, bytesPerPixel: Int, x: Int, y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = (plane.map { CVPixelBufferGetBaseAddressOfPlane(buffer, $0) } ?? CVPixelBufferGetBaseAddress(buffer))!
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = plane.map { CVPixelBufferGetBytesPerRowOfPlane(buffer, $0) } ?? CVPixelBufferGetBytesPerRow(buffer)
        return base[y * rowBytes + x * bytesPerPixel]
    }

    @Test func fillsWithTheColumnRightOfTheIndicator() throws {
        let buffer = try makeBuffer(kCVPixelFormatType_444YpCbCr8BiPlanarFullRange)
        // A distinct value per column and plane; the "indicator" spans columns 5..<15.
        paint(buffer, planes: [(0, 1), (1, 2)]) { x, plane in UInt8(x * 3 + plane * 100) }
        SharingIndicatorConcealer.conceal(CGRect(x: 5, y: 2, width: 10, height: 4), in: buffer)
        for x in 5..<15 {
            #expect(byte(buffer, plane: 0, bytesPerPixel: 1, x: x, y: 3) == 45)  // column 15
            #expect(byte(buffer, plane: 1, bytesPerPixel: 2, x: x, y: 3) == 145)
        }
        // Rows outside the area and the columns beside it are untouched.
        #expect(byte(buffer, plane: 0, bytesPerPixel: 1, x: 7, y: 1) == 21)
        #expect(byte(buffer, plane: 0, bytesPerPixel: 1, x: 7, y: 6) == 21)
        #expect(byte(buffer, plane: 0, bytesPerPixel: 1, x: 4, y: 3) == 12)
    }

    @Test func bgraAndClipping() throws {
        let buffer = try makeBuffer(kCVPixelFormatType_32BGRA)
        paint(buffer, planes: [(nil, 4)]) { x, _ in UInt8(x) }
        // Reaches past the right edge: filled from the column left of it.
        SharingIndicatorConcealer.conceal(CGRect(x: 30, y: -3, width: 20, height: 20), in: buffer)
        #expect(byte(buffer, plane: nil, bytesPerPixel: 4, x: 35, y: 0) == 29)
        #expect(byte(buffer, plane: nil, bytesPerPixel: 4, x: 39, y: 9) == 29)
        #expect(byte(buffer, plane: nil, bytesPerPixel: 4, x: 29, y: 5) == 29)
    }
}
