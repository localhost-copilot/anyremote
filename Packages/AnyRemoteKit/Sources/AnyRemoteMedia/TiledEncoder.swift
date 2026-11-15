import AnyRemoteWire
import CoreVideo
import Foundation
import Metal
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Encoder")

/// Encodes a picture as horizontal strips, each with its own HEVC session,
/// the way Apple Screen Sharing sends a display as four tiles.
///
/// Only strips that changed (ScreenCaptureKit's dirty rects) are copied out
/// (a GPU blit) and encoded, so typing or a scrolling window costs a
/// quarter of a full-screen encode, and the strips of a full-screen change
/// encode, travel and decode overlapped. Measured on M4 (3840×2160): typing
/// 21 → 11 ms from capture to decoded, full-screen motion 15 → 14 ms.
///
/// Every strip of a host frame carries the frame's display time and the
/// mask of strips sent, so the viewer can show them together.
/// Hands the copied strips to the blit's completion handler.
private struct StripBatch: @unchecked Sendable {
    let textures: [CVMetalTexture]
    let strips: [(encoder: HEVCEncoder, pixels: CVPixelBuffer, tile: EncodedVideoFrame.Tile)]
}

final class TiledEncoder: @unchecked Sendable {
    private struct Strip {
        let streamID: UInt16
        let encoder: HEVCEncoder
        var y = 0
        var height = 0
        /// Send on the next frame whether or not it changed (new layout, keyframe).
        var needsRefresh = true
    }

    private let queue = DispatchQueue(label: "anyremote.tiles", qos: .userInteractive)
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    // Queue-confined.
    private var strips: [Strip]
    private var width = 0
    private var height = 0
    private var pool: [Int: CVPixelBufferPool] = [:] // by strip height
    private var lastFrame: CapturedFrame?

    /// - Parameter output: the encoded strip and the stream it belongs to; on encoder queues.
    init?(streamIDs: [UInt16], configuration: HEVCEncoder.Configuration,
          output: @escaping @Sendable (_ streamID: UInt16, HEVCEncoder.Output) -> Void) {
        guard streamIDs.count > 1, streamIDs.count <= 8,
              let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = cache
        var perStrip = configuration
        perStrip.averageBitRate = configuration.averageBitRate / streamIDs.count
        strips = streamIDs.map { streamID in
            Strip(streamID: streamID, encoder: HEVCEncoder(configuration: perStrip) { output(streamID, $0) })
        }
    }

    func encode(_ frame: CapturedFrame) {
        queue.async { [self] in
            lastFrame = frame
            split(frame)
        }
    }

    /// The strip sent under `streamID` (every strip when nil) is sent again,
    /// as a keyframe, right away (the picture may not change for a while).
    /// Each strip's receiver asks for its own: refreshing all four on every
    /// request multiplied keyframes by four under loss (2% loss: ~40 a second).
    func requestKeyframe(streamID: UInt16? = nil) {
        queue.async { [self] in
            var any = false
            for index in strips.indices where streamID == nil || strips[index].streamID == streamID {
                strips[index].needsRefresh = true
                strips[index].encoder.requestKeyframe()
                any = true
            }
            // Only the strips that need it: no dirty rects.
            if any, var lastFrame {
                lastFrame.dirtyRects = []
                split(lastFrame)
            }
        }
    }

    func setAverageBitRate(_ bitRate: Int) {
        queue.async { [self] in
            for strip in strips { strip.encoder.setAverageBitRate(bitRate / strips.count) }
        }
    }

    func invalidate() {
        queue.sync {
            lastFrame = nil
            pool = [:]
        }
        for strip in strips { strip.encoder.invalidate() }
    }

    /// Queue-confined.
    private func split(_ frame: CapturedFrame) {
        let source = frame.pixelBuffer
        let frameWidth = CVPixelBufferGetWidth(source)
        let frameHeight = CVPixelBufferGetHeight(source)
        guard CVPixelBufferGetPlaneCount(source) == 2,
              frameHeight <= Int(UInt16.max) else { return }
        if frameWidth != width || frameHeight != height {
            width = frameWidth
            height = frameHeight
            pool = [:]
            let layout = TileLayout.strips(pixelHeight: frameHeight, count: strips.count)
            for index in strips.indices {
                // A picture too small for every strip leaves the rest empty.
                let part: (y: Int, height: Int) = index < layout.count ? layout[index] : (frameHeight, 0)
                strips[index].y = part.y
                strips[index].height = part.height
                strips[index].needsRefresh = true
            }
        }
        var selected: [Int] = []
        for (index, strip) in strips.enumerated() where strip.height > 0 {
            let changed = strip.needsRefresh || (frame.dirtyRects.map { rects in
                rects.contains { $0.maxY > CGFloat(strip.y) && $0.minY < CGFloat(strip.y + strip.height) && !$0.isEmpty }
            } ?? true)
            if changed { selected.append(index) }
        }
        guard !selected.isEmpty else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        var retained: [CVMetalTexture] = []
        var parts: [(index: Int, buffer: CVPixelBuffer)] = []
        for index in selected {
            let strip = strips[index]
            guard let buffer = makeBuffer(height: strip.height) else { continue }
            CVBufferPropagateAttachments(source, buffer)
            var copied = true
            for (plane, format) in [(0, MTLPixelFormat.r8Unorm), (1, .rg8Unorm)] {
                guard let from = texture(source, plane: plane, format: format, retaining: &retained),
                      let to = texture(buffer, plane: plane, format: format, retaining: &retained) else {
                    copied = false
                    break
                }
                blit.copy(from: from, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: strip.y, z: 0),
                          sourceSize: MTLSize(width: frameWidth, height: strip.height, depth: 1),
                          to: to, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            }
            if copied { parts.append((index, buffer)) }
        }
        blit.endEncoding()
        let canvasHeight = UInt16(frameHeight)
        let sentMask = parts.reduce(UInt8(0)) { $0 | UInt8(1 << $1.index) }
        guard sentMask != 0 else { return }
        let batch = StripBatch(textures: retained, strips: parts.map { part in
            (strips[part.index].encoder, part.buffer,
             EncodedVideoFrame.Tile(index: UInt8(part.index), mask: sentMask,
                                    originY: UInt16(strips[part.index].y), canvasHeight: canvasHeight))
        })
        for part in parts { strips[part.index].needsRefresh = false }
        let scale = frame.scale
        commandBuffer.addCompletedHandler { buffer in
            withExtendedLifetime(batch.textures) {}
            guard buffer.status == .completed else {
                log.error("strip copy failed: \(String(describing: buffer.error), privacy: .public)")
                return
            }
            for (encoder, pixels, tile) in batch.strips {
                var strip = CapturedFrame(
                    pixelBuffer: pixels, captureTimeNanos: frame.captureTimeNanos,
                    deliveredTimeNanos: frame.deliveredTimeNanos,
                    pointSize: CGSize(width: CGFloat(frameWidth) / scale,
                                      height: CGFloat(CVPixelBufferGetHeight(pixels)) / scale),
                    scale: scale)
                strip.tile = tile
                encoder.encode(strip)
            }
        }
        commandBuffer.commit()
    }

    private func makeBuffer(height stripHeight: Int) -> CVPixelBuffer? {
        if pool[stripHeight] == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: WindowCaptureSession.pixelFormat,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: stripHeight,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
            pool[stripHeight] = created
        }
        guard let pool = pool[stripHeight] else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                         retaining: inout [CVMetalTexture]) -> MTLTexture? {
        var texture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane),
            plane, &texture) == kCVReturnSuccess, let texture, let metal = CVMetalTextureGetTexture(texture)
        else { return nil }
        retaining.append(texture)
        return metal
    }
}
