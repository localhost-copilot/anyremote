import CoreGraphics
import CoreVideo

/// A window's shape (its own alpha), cut out of frames that show more than
/// the window: a display capture of the window together with what lies
/// beneath it. Only the pixels that aren't fully opaque are touched (rounded
/// corners and antialiased edges), so applying it costs little.
struct WindowShapeMask: Sendable {
    let width: Int
    let height: Int
    /// Rows' runs of pixels that aren't fully opaque, with their alpha.
    private let runs: [(row: Int, start: Int, alphas: [UInt8])]

    /// Reads the shape from a capture of the window alone (without shadow).
    init?(image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // BGRA, top row first; the alpha is every fourth byte.
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        func alpha(_ row: Int, _ column: Int) -> UInt8 { bytes[(row * width + column) * 4 + 3] }
        var runs: [(row: Int, start: Int, alphas: [UInt8])] = []
        for row in 0..<height {
            var column = 0
            while column < width {
                guard alpha(row, column) < 255 else { column += 1; continue }
                let start = column
                var alphas: [UInt8] = []
                while column < width, alpha(row, column) < 255 {
                    alphas.append(alpha(row, column))
                    column += 1
                }
                runs.append((row, start, alphas))
            }
        }
        self.width = width
        self.height = height
        self.runs = runs
    }

    func fits(_ pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetWidth(pixelBuffer) == width && CVPixelBufferGetHeight(pixelBuffer) == height
    }

    /// Scales premultiplied BGRA pixels by the shape's alpha.
    func apply(to pixelBuffer: CVPixelBuffer) {
        guard fits(pixelBuffer), CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for run in runs {
            var offset = run.row * bytesPerRow + run.start * 4
            for alpha in run.alphas {
                let a = UInt16(alpha)
                for channel in 0..<4 {
                    pixels[offset + channel] = UInt8((UInt16(pixels[offset + channel]) * a + 127) / 255)
                }
                offset += 4
            }
        }
    }
}
