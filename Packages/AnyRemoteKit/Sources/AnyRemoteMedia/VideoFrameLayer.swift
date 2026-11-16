import AnyRemoteWire
import CoreText
import CoreVideo
import Metal
import OSLog
import QuartzCore

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Render")

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Matches `AreaParameters` in the shader (float2 + int, 16-byte stride).
private struct AreaParameters {
    var footprint: SIMD2<Float>
    var taps: Int32
}

private struct RetainedTextures: @unchecked Sendable {
    let textures: [CVMetalTexture]
}

/// What one drawable shows: a frame, or the strips of a tiled stream.
private struct Picture: @unchecked Sendable {
    var parts: [DecodedFrame]
    /// The part that completed it, for statistics.
    var lead: DecodedFrame
    var width: Int
    var height: Int

    init(_ frame: DecodedFrame) {
        parts = [frame]
        lead = frame
        width = frame.pixelWidth
        height = frame.pixelHeight
    }

    init(parts: [DecodedFrame], lead: DecodedFrame, width: Int, height: Int) {
        self.parts = parts
        self.lead = lead
        self.width = width
        self.height = height
    }

    var isTiled: Bool { lead.tile != nil }
}

final class NV24MetalContext: @unchecked Sendable {
    static let shared = NV24MetalContext()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let alphaPipeline: MTLRenderPipelineState
    /// Premultiplied BGRA blended over what is drawn (the statistics overlay).
    let overlayPipeline: MTLRenderPipelineState
    /// 4:4:4 with an area (box) filter, for pictures drawn smaller than their pixels.
    let areaPipeline: MTLRenderPipelineState
    let textureCache: CVMetalTextureCache

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertex = library.makeFunction(name: "fullscreenVertex"),
              let fragment = library.makeFunction(name: "nv24Fragment"),
              let alphaFragment = library.makeFunction(name: "bgraFragment"),
              let areaFragment = library.makeFunction(name: "nv24AreaFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let alphaDescriptor = MTLRenderPipelineDescriptor()
        alphaDescriptor.vertexFunction = vertex
        alphaDescriptor.fragmentFunction = alphaFragment
        alphaDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let areaDescriptor = MTLRenderPipelineDescriptor()
        areaDescriptor.vertexFunction = vertex
        areaDescriptor.fragmentFunction = areaFragment
        areaDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let overlayDescriptor = MTLRenderPipelineDescriptor()
        overlayDescriptor.vertexFunction = vertex
        overlayDescriptor.fragmentFunction = alphaFragment
        overlayDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        overlayDescriptor.colorAttachments[0].isBlendingEnabled = true
        overlayDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        overlayDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        overlayDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        overlayDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        var cache: CVMetalTextureCache?
        guard let overlayPipeline = try? device.makeRenderPipelineState(descriptor: overlayDescriptor),
              let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let areaPipeline = try? device.makeRenderPipelineState(descriptor: areaDescriptor),
              let alphaPipeline = try? device.makeRenderPipelineState(descriptor: alphaDescriptor),
              CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.alphaPipeline = alphaPipeline
        self.overlayPipeline = overlayPipeline
        self.areaPipeline = areaPipeline
        self.textureCache = cache
    }

    // Full-range BT.709 Y'CbCr → R'G'B'. Same conversion as iScreenSharing's
    // NV24 renderer; full-res chroma so text edges stay sharp.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOutput {
        float4 position [[position]];
        float2 textureCoordinate;
    };

    vertex VertexOutput fullscreenVertex(uint index [[vertex_id]]) {
        const float2 positions[4] = { {-1, -1}, {1, -1}, {-1, 1}, {1, 1} };
        const float2 coordinates[4] = { {0, 1}, {1, 1}, {0, 0}, {1, 0} };
        return { float4(positions[index], 0.0, 1.0), coordinates[index] };
    }

    fragment float4 nv24Fragment(
        VertexOutput input [[stage_in]],
        texture2d<float> luma [[texture(0)]],
        texture2d<float> chroma [[texture(1)]]) {
        constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);
        const float y = luma.sample(textureSampler, input.textureCoordinate).r;
        const float2 uv = chroma.sample(textureSampler, input.textureCoordinate).rg - 0.5;
        const float3 rgb = float3(
            y + 1.5748 * uv.y,
            y - 0.187324 * uv.x - 0.468124 * uv.y,
            y + 1.8556 * uv.x
        );
        return float4(rgb, 1.0);
    }

    // Area-averaged 4:4:4: `taps`×`taps` bilinear samples spread over the
    // source footprint of one output pixel. Plain bilinear minification
    // skips texels once the picture is drawn below half size, so text
    // shimmers and thin lines vanish; averaging the footprint keeps them.
    struct AreaParameters {
        float2 footprint;
        int taps;
    };

    fragment float4 nv24AreaFragment(
        VertexOutput input [[stage_in]],
        texture2d<float> luma [[texture(0)]],
        texture2d<float> chroma [[texture(1)]],
        constant AreaParameters &parameters [[buffer(0)]]) {
        constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);
        float y = 0;
        float2 uv = 0;
        const int taps = parameters.taps;
        for (int row = 0; row < taps; row++) {
            for (int column = 0; column < taps; column++) {
                const float2 offset = (float2(column, row) + 0.5) / float(taps) - 0.5;
                const float2 coordinate = input.textureCoordinate + offset * parameters.footprint;
                y += luma.sample(textureSampler, coordinate).r;
                uv += chroma.sample(textureSampler, coordinate).rg;
            }
        }
        const float count = float(taps * taps);
        y /= count;
        uv = uv / count - 0.5;
        const float3 rgb = float3(
            y + 1.5748 * uv.y,
            y - 0.187324 * uv.x - 0.468124 * uv.y,
            y + 1.8556 * uv.x
        );
        return float4(rgb, 1.0);
    }

    // Premultiplied BGRA (alpha streams): passed through unchanged.
    fragment float4 bgraFragment(
        VertexOutput input [[stage_in]],
        texture2d<float> image [[texture(0)]]) {
        constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);
        return image.sample(textureSampler, input.textureCoordinate);
    }
    """
}

/// Presents decoded frames, paced (see `FramePacer`), latest wins: `444f`, or
/// premultiplied BGRA for alpha streams (the layer is then non-opaque).
///
/// The drawable is sized to the frame's pixels. When the hosting view's
/// backing size equals that, presentation is a 1:1 copy, which is what makes
/// a remote window look native.
public final class VideoFrameLayer: CAMetalLayer, @unchecked Sendable {
    public var stats: PipelineStats?
    /// Maps capture timestamps into this machine's clock for the `total`
    /// stage; nil records no end-to-end latency.
    public var remoteClock: RemoteClock?
    /// Called on the main queue when a frame with a new pixel size or scale is presented.
    public var onGeometryChange: (@MainActor (_ pixelWidth: Int, _ pixelHeight: Int, _ scale: Int) -> Void)?

    private let renderQueue = DispatchQueue(label: "anyremote.render", qos: .userInteractive)
    private let lock = NSLock()
    /// Frames waiting for their presentation time, oldest first. Under `lock`.
    private var waiting: [(picture: Picture, due: UInt64, paced: Bool)] = []
    private var inFlight = false
    private var wakeScheduledFor: UInt64 = 0
    private let pacer = FramePacer()
    private var lastGeometry: (Int, Int, Int) = (0, 0, 0)
    private var lastPicture: Picture?
    // Strips (under `lock`): the latest of each, and the host frame being gathered.
    private var strips: [Int: DecodedFrame] = [:]
    private var stripCanvas = (width: 0, height: 0)
    private var gathering: (time: UInt64, mask: UInt8, arrived: UInt8, frames: [DecodedFrame])?
    /// How long a host frame's strips wait for the rest before showing without them.
    private static let gatherTimeout: UInt64 = 10_000_000
    private var targetSize: CGSize?
    private var overlay: MTLTexture? // under `lock`

    /// When set, frames are scaled here to this drawable size (pixels),
    /// aspect-fitted and centered on black, with an area filter, instead of
    /// being drawn at their own size and scaled by the compositor.
    /// Thread-safe.
    public var targetPixelSize: CGSize? {
        get { lock.lock(); defer { lock.unlock() }; return targetSize }
        set { lock.lock(); targetSize = newValue; lock.unlock() }
    }

    public override init() {
        super.init()
        configure()
    }

    public override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        guard let context = NV24MetalContext.shared else {
            log.fault("Metal unavailable")
            return
        }
        device = context.device
        pixelFormat = .bgra8Unorm
        framebufferOnly = true
        maximumDrawableCount = 2
        // Windowed layers are composited by WindowServer, so presenting
        // without vsync does not tear; it only stops the drawable from
        // waiting an extra refresh before the compositor picks it up.
        // Measured on a 60 Hz display: decode→glass 25 ms → 7 ms.
        // ANYREMOTE_DISPLAY_SYNC=1 restores vsync for comparison.
        displaySyncEnabled = ProcessInfo.processInfo.environment["ANYREMOTE_DISPLAY_SYNC"] == "1"
        presentsWithTransaction = false
        isOpaque = true
        colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        contentsGravity = .resize
        magnificationFilter = .linear
        minificationFilter = .linear
    }

    /// An image drawn over the top-right corner of every frame (the
    /// statistics panel), or nil. Premultiplied, at the layer's scale.
    ///
    /// Drawn into the frame itself: a view over the video made the window
    /// server composite (rather than show the video directly) on every update
    /// in full screen, a stutter a second. Thread-safe.
    public func setOverlay(_ image: CGImage?) {
        let texture = image.flatMap(Self.overlayTexture)
        lock.lock()
        let had = overlay != nil
        overlay = texture
        lock.unlock()
        if had || texture != nil { redrawLastFrame() }
    }

    private static func overlayTexture(_ image: CGImage) -> MTLTexture? {
        guard let device = NV24MetalContext.shared?.device else { return nil }
        let width = min(8192, image.width), height = min(8192, image.height)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor), let data = context.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: width * 4)
        return texture
    }

    /// Frame pacing state, for statistics.
    public var pacingDescription: String { pacer.description }

    /// Thread-safe. Strips of a tiled stream (from every strip's receiver)
    /// are shown together: those of one host frame wait for each other.
    public func enqueue(_ frame: DecodedFrame) {
        if let tile = frame.tile {
            gather(frame, tile: tile)
        } else {
            schedule(Picture(frame))
        }
    }

    private func schedule(_ picture: Picture) {
        let displayTime = remoteClock?.localTime(fromSender: picture.lead.captureTimeNanos)
        let due = pacer.due(displayTime: displayTime, decoded: picture.lead.decodedTimeNanos)
        add(picture, due: due ?? picture.lead.decodedTimeNanos, paced: true)
    }

    /// Redraws the most recent picture, e.g. after the layer was resized.
    public func redrawLastFrame() {
        lock.lock()
        let picture = lastPicture
        lock.unlock()
        if let picture {
            add(picture, due: 0, paced: false)
        } else {
            // Nothing received yet: the statistics still show (on black).
            renderQueue.async { self.renderOverlayOnly() }
        }
    }

    /// Render queue. Black with the overlay, before any frame arrives.
    private func renderOverlayOnly() {
        guard let context = NV24MetalContext.shared else { return }
        lock.lock()
        let busy = inFlight || lastPicture != nil
        if !busy { inFlight = true }
        let target = targetSize
        lock.unlock()
        guard !busy else { return }
        let size = target ?? CGSize(width: bounds.width * contentsScale, height: bounds.height * contentsScale)
        guard size.width >= 2, size.height >= 2 else { return finish() }
        let pixels = CGSize(width: size.width.rounded(), height: size.height.rounded())
        if drawableSize != pixels { drawableSize = pixels }
        guard let drawable = nextDrawable(), let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            return finish()
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return finish() }
        drawOverlay(encoder, context: context, target: drawable.texture)
        encoder.endEncoding()
        let release = OnceFlag()
        drawable.addPresentedHandler { [weak self] _ in if release.claim() { self?.finish() } }
        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard buffer.status != .completed else { return }
            if release.claim() { self?.finish() }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// The statistics panel, top right, 10 points in (clipped to the drawable).
    private func drawOverlay(_ encoder: MTLRenderCommandEncoder, context: NV24MetalContext, target: MTLTexture) {
        lock.lock()
        let overlayTexture = overlay
        lock.unlock()
        guard let overlayTexture else { return }
        let margin = Double((10 * max(1, contentsScale)).rounded())
        let x = max(0, Double(target.width) - margin - Double(overlayTexture.width)), y = margin
        let visibleWidth = min(Double(overlayTexture.width), Double(target.width) - x)
        guard visibleWidth > 0, y + Double(overlayTexture.height) <= Double(target.height) else { return }
        encoder.setRenderPipelineState(context.overlayPipeline)
        encoder.setViewport(MTLViewport(originX: x, originY: y, width: Double(overlayTexture.width),
                                        height: Double(overlayTexture.height), znear: 0, zfar: 1))
        encoder.setScissorRect(MTLScissorRect(x: Int(x), y: Int(y), width: Int(visibleWidth),
                                              height: overlayTexture.height))
        encoder.setFragmentTexture(overlayTexture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func add(_ picture: Picture, due: UInt64, paced: Bool) {
        lock.lock()
        waiting.append((picture, due, paced))
        lock.unlock()
        renderQueue.async { self.pump() }
    }

    private func gather(_ frame: DecodedFrame, tile: EncodedVideoFrame.Tile) {
        let time = frame.captureTimeNanos
        let bit = UInt8(1) << tile.index
        var ready: [[DecodedFrame]] = []
        var startedGathering = false
        lock.lock()
        if var current = gathering, current.time == time {
            current.arrived |= bit
            current.frames.append(frame)
            gathering = current
        } else if gathering == nil || time > gathering!.time {
            // A newer host frame: the previous one shows with what arrived.
            if let previous = gathering { ready.append(previous.frames) }
            gathering = (time, tile.mask, bit, [frame])
            startedGathering = true
        } else {
            // A straggler from an older host frame.
            ready.append([frame])
        }
        if let current = gathering, current.arrived & current.mask == current.mask {
            ready.append(current.frames)
            gathering = nil
        }
        let pictures = ready.compactMap(commitLocked)
        lock.unlock()
        pictures.forEach(schedule)
        if startedGathering, gathering(isStillAt: time) {
            renderQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(Self.gatherTimeout))) { [weak self] in
                self?.gatherTimedOut(time)
            }
        }
    }

    private func gathering(isStillAt time: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gathering?.time == time
    }

    private func gatherTimedOut(_ time: UInt64) {
        lock.lock()
        var picture: Picture?
        if let current = gathering, current.time == time {
            gathering = nil
            picture = commitLocked(current.frames)
        }
        lock.unlock()
        if let picture { schedule(picture) }
    }

    /// Under `lock`. Stores strips (unless newer ones are stored) and returns the whole picture.
    private func commitLocked(_ frames: [DecodedFrame]) -> Picture? {
        var lead: DecodedFrame?
        for frame in frames {
            guard let tile = frame.tile else { continue }
            let canvas = (width: frame.pixelWidth, height: Int(tile.canvasHeight))
            if canvas != stripCanvas {
                // A new size: strips of the old one no longer fit.
                stripCanvas = canvas
                strips = [:]
            }
            let index = Int(tile.index)
            if let stored = strips[index], stored.captureTimeNanos > frame.captureTimeNanos { continue }
            strips[index] = frame
            if lead == nil || frame.decodedTimeNanos > lead!.decodedTimeNanos { lead = frame }
        }
        guard let lead else { return nil }
        let parts = strips.keys.sorted().compactMap { strips[$0] }
        return Picture(parts: parts, lead: lead, width: stripCanvas.width, height: stripCanvas.height)
    }

    /// Render queue. Renders the newest frame that is due, unless one is
    /// still on its way to the screen; otherwise wakes up when one is due.
    private func pump() {
        let now = HostClock.nowNanos()
        lock.lock()
        guard !inFlight else { return lock.unlock() }
        // A timer fires a little early; within 0.3 ms counts as due.
        guard let index = waiting.lastIndex(where: { $0.due <= now + 300_000 }) else {
            if let next = waiting.map(\.due).min(), next != wakeScheduledFor {
                wakeScheduledFor = next
                lock.unlock()
                renderQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: next)) { self.pump() }
                return
            }
            return lock.unlock()
        }
        // A redraw (overlay, resize) behind a newer frame: that frame does it.
        var shown = index
        if !waiting[index].paced, let newer = waiting[..<index].lastIndex(where: \.paced) { shown = newer }
        let chosen = waiting[shown]
        let skipped = waiting[..<shown].filter(\.paced).count
        waiting.removeFirst(index + 1)
        inFlight = true
        lock.unlock()
        for _ in 0..<skipped { stats?.recordSkipped() }
        if chosen.paced { stats?.record(.hold, from: chosen.picture.lead.decodedTimeNanos, to: now) }
        let held = chosen.paced && now > chosen.picture.lead.decodedTimeNanos + 500_000
        render(chosen.picture, startedAt: held ? 0 : now)
    }

    private func finish() {
        lock.lock()
        inFlight = false
        lock.unlock()
        renderQueue.async { self.pump() }
    }

    private var lastCadence: (captured: UInt64, presented: UInt64)? // under `lock`

    /// Smoothness: a frame that reaches the screen a refresh or more after
    /// the previous one, although the host captured it about one frame
    /// later, shows as a stutter.
    private func recordCadence(captured: UInt64, presented: UInt64) {
        lock.lock()
        let previous = lastCadence
        lastCadence = (captured, presented)
        lock.unlock()
        guard let last = previous, captured > last.captured, presented > last.presented else { return }
        let captureGap = Double(captured - last.captured) / 1_000_000
        let presentGap = Double(presented - last.presented) / 1_000_000
        // Only while content moves continuously.
        guard captureGap < 50 else { return }
        stats?.record(.captureGap, milliseconds: captureGap)
        stats?.record(.presentGap, milliseconds: presentGap)
        if presentGap - captureGap > 12 { stats?.recordHitch() }
    }

    /// - Parameter startedAt: when a frame that wasn't held back was taken; 0 if it was.
    private func render(_ picture: Picture, startedAt: UInt64) {
        guard let context = NV24MetalContext.shared else { return finish() }
        let frame = picture.lead
        let width = picture.width
        let height = picture.height
        guard width > 0, height > 0 else { return finish() }
        if frame.hasAlpha == isOpaque {
            isOpaque = !frame.hasAlpha
        }
        // Where the whole picture goes in the drawable.
        var placement = CGRect(x: 0, y: 0, width: width, height: height)
        var taps: Int32?
        // Scaled here (desktops): the drawable takes the view's pixel size.
        if !frame.hasAlpha, let target = targetPixelSize, target.width >= 2, target.height >= 2 {
            let target = CGSize(width: target.width.rounded(), height: target.height.rounded())
            if drawableSize != target { drawableSize = target }
            let factor = min(target.width / CGFloat(width), target.height / CGFloat(height))
            let size = CGSize(width: (CGFloat(width) * factor).rounded(), height: (CGFloat(height) * factor).rounded())
            placement = CGRect(x: ((target.width - size.width) / 2).rounded(),
                               y: ((target.height - size.height) / 2).rounded(),
                               width: size.width, height: size.height)
            // Source texels per output pixel.
            taps = Int32(min(6, max(1, (1 / factor).rounded(.up))))
        } else if drawableSize.width != CGFloat(width) || drawableSize.height != CGFloat(height) {
            drawableSize = CGSize(width: width, height: height)
        }
        let scaleY = placement.height / CGFloat(height)

        var textures: [CVMetalTexture] = []
        var draws: [(textures: [MTLTexture], viewport: MTLViewport)] = []
        for part in picture.parts {
            var partTextures: [CVMetalTexture] = []
            if part.hasAlpha {
                guard let image = makeTexture(context, part.pixelBuffer, plane: 0, format: .bgra8Unorm,
                                              planar: false) else { continue }
                partTextures = [image]
            } else {
                guard CVPixelBufferGetPlaneCount(part.pixelBuffer) == 2,
                      let luma = makeTexture(context, part.pixelBuffer, plane: 0, format: .r8Unorm),
                      let chroma = makeTexture(context, part.pixelBuffer, plane: 1, format: .rg8Unorm)
                else { continue }
                partTextures = [luma, chroma]
            }
            let metal = partTextures.compactMap { CVMetalTextureGetTexture($0) }
            guard metal.count == partTextures.count else { continue }
            textures += partTextures
            // Metal viewports are top-left origin, like the strips.
            let originY = CGFloat(part.tile?.originY ?? 0)
            let viewport = MTLViewport(originX: Double(placement.minX),
                                       originY: Double(placement.minY + originY * scaleY),
                                       width: Double(placement.width),
                                       height: Double(CGFloat(part.pixelHeight) * scaleY), znear: 0, zfar: 1)
            draws.append((metal, viewport))
        }
        guard !draws.isEmpty,
              let drawable = nextDrawable(),
              let commandBuffer = context.commandQueue.makeCommandBuffer() else { return finish() }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        let letterboxed = placement.width < CGFloat(drawable.texture.width) || placement.height < CGFloat(drawable.texture.height)
        // Strips not received yet show black.
        pass.colorAttachments[0].loadAction = letterboxed || picture.isTiled ? .clear : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return finish() }
        if taps != nil {
            encoder.setRenderPipelineState(context.areaPipeline)
        } else {
            encoder.setRenderPipelineState(frame.hasAlpha ? context.alphaPipeline : context.pipeline)
        }
        for draw in draws {
            encoder.setViewport(draw.viewport)
            if let taps {
                // One output pixel's footprint in this part's texture coordinates.
                var parameters = AreaParameters(footprint: SIMD2(Float(1 / draw.viewport.width),
                                                                 Float(1 / draw.viewport.height)), taps: taps)
                encoder.setFragmentBytes(&parameters, length: MemoryLayout<AreaParameters>.stride, index: 0)
            }
            for (index, texture) in draw.textures.enumerated() {
                encoder.setFragmentTexture(texture, index: index)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        drawOverlay(encoder, context: context, target: drawable.texture)
        encoder.endEncoding()

        // Admit the next frame only once this one is on glass. Releasing on
        // GPU completion lets a second drawable queue behind the compositor,
        // which costs a full refresh interval of latency.
        let stats = stats
        let remoteClock = remoteClock
        let release = OnceFlag()
        // Core Video textures must outlive GPU use of the IOSurface.
        let retained = RetainedTextures(textures: textures)
        drawable.addPresentedHandler { [weak self] drawable in
            withExtendedLifetime(retained) {}
            let presented = HostClock.nanos(fromSeconds: drawable.presentedTime)
            if presented > 0 {
                self?.pacer.presented(startedAt: startedAt, presented: presented)
                self?.recordCadence(captured: frame.captureTimeNanos, presented: presented)
                stats?.record(.present, from: frame.decodedTimeNanos, to: presented)
                if let captured = remoteClock?.localTime(fromSender: frame.handedOverTimeNanos) {
                    stats?.record(.total, from: captured, to: presented)
                }
            }
            if release.claim() { self?.finish() }
        }
        commandBuffer.addCompletedHandler { [weak self] buffer in
            // Safety net: a drawable that is never presented must not wedge the gate.
            guard buffer.status != .completed else { return }
            if release.claim() { self?.finish() }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        lock.lock()
        lastPicture = picture
        lock.unlock()

        let geometry = (width, height, Int(frame.scale))
        if geometry != lastGeometry {
            lastGeometry = geometry
            let callback = onGeometryChange
            DispatchQueue.main.async {
                MainActor.assumeIsolated { callback?(geometry.0, geometry.1, geometry.2) }
            }
        }
    }

    private func makeTexture(
        _ context: NV24MetalContext, _ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
        planar: Bool = true
    ) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, context.textureCache, buffer, nil, format,
            planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer),
            planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer),
            plane, &texture
        )
        return status == kCVReturnSuccess ? texture : nil
    }
}

/// Paces presentation so motion is as even on this screen as on the host's.
///
/// The host's display times are exactly one refresh apart, but frames reach
/// this Mac with a few milliseconds of jitter (encode, network, decode).
/// Presented on arrival, a frame that lands near this screen's compositor
/// deadline makes it one refresh and misses the next, so some refreshes show
/// two new frames (one never seen) and others none: a stutter, 1-2 times a
/// second measured between two Macs. Instead each frame is due at its host
/// display time plus `delay`, the 95th percentile of recent arrivals (at most
/// 5 ms more than the median), so the due times are as even as the host's;
/// one that arrives later than that is shown on arrival. Due times that would fall just before the compositor's
/// deadline are moved just past it, so jitter never decides which refresh a
/// frame makes. Costs the jitter (the 95th percentile minus each frame's
/// own arrival).
///
/// Off unless `ANYREMOTE_PACING=1`: measured between two Macs (M4 host, 60 Hz
/// viewer) it added 5-6 ms to every frame and did not reliably reduce
/// stutters (windowed 0.41 → 0.61/s, full screen 1.00 → 0.44/s).
final class FramePacer: @unchecked Sendable {
    private static let enabled = ProcessInfo.processInfo.environment["ANYREMOTE_PACING"] == "1"
    private let lock = NSLock()
    /// Arrival (decoded) − host display time, nanoseconds; may be negative.
    private var arrivals: [Int64] = []
    private var delay: Int64?
    private var sinceUpdate = 0
    /// Presentation feedback.
    private var lastPresented: UInt64 = 0
    private var refreshGaps: [UInt64] = []
    private var refresh: UInt64 = 16_666_667
    private var fixedRefresh = false
    /// Render start → on glass for frames started at random phases: the
    /// shortest is how long before a refresh the compositor's deadline is.
    private var deadlineLeads: [UInt64] = []
    private var deadlineLead: UInt64?
    private var pushing = false

    private static let window = 120
    /// The most frame pacing adds to the typical frame.
    private static let maximumHold: Int64 = 5_000_000
    private static let margin: Int64 = 2_000_000

    /// When `decoded`, a frame shown on the host at `displayTime` (this
    /// Mac's clock), should be presented; nil: right away.
    func due(displayTime: UInt64?, decoded: UInt64) -> UInt64? {
        guard Self.enabled, let displayTime else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let arrival = Int64(bitPattern: decoded) &- Int64(bitPattern: displayTime)
        // A pause (static content, a reconnect) isn't jitter.
        if abs(arrival) < 200_000_000 {
            arrivals.append(arrival)
            if arrivals.count > Self.window { arrivals.removeFirst(arrivals.count - Self.window) }
        }
        sinceUpdate += 1
        if arrivals.count >= 30, delay == nil || sinceUpdate >= 15 {
            sinceUpdate = 0
            let sorted = arrivals.sorted()
            // Rare stragglers are shown on arrival rather than delaying every frame.
            let typical = sorted[sorted.count / 2]
            delay = min(sorted[Int(Double(sorted.count - 1) * 0.95)], typical + Self.maximumHold) + 300_000
        }
        guard let delay else { return nil }
        var due = UInt64(bitPattern: Int64(bitPattern: displayTime) &+ delay)
        if due <= decoded { return nil }
        // Keep clear of the compositor's deadline (fixed refresh rates only).
        if fixedRefresh, let deadlineLead, lastPresented > 0 {
            let deadline = lastPresented &- deadlineLead
            let period = Int64(refresh)
            let untilDeadline = ((Int64(bitPattern: deadline) &- Int64(bitPattern: due)) % period + period) % period
            // Hysteresis: once pushing, keep pushing a little longer.
            let zone = Self.margin + (pushing ? 1_000_000 : 0)
            pushing = untilDeadline < zone
            if pushing { due += UInt64(untilDeadline) + 500_000 }
        }
        return due
    }

    var description: String {
        lock.lock()
        defer { lock.unlock() }
        guard Self.enabled else { return "" }
        guard let delay else { return "pacing warming up" }
        let deadline = deadlineLead.map { String(format: "%.1f", Double($0) / 1e6) } ?? "?"
        return String(format: "pacing +%.1f ms · refresh %.2f ms%@ · deadline −%@ ms%@",
                      Double(delay) / 1e6, Double(refresh) / 1e6, fixedRefresh ? "" : " (variable)",
                      deadline, pushing ? " · pushed" : "")
    }

    /// - Parameter startedAt: when rendering began, for frames not held back; else 0.
    func presented(startedAt: UInt64, presented: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if lastPresented > 0, presented > lastPresented {
            let gap = presented - lastPresented
            if gap > 4_000_000, gap < 25_000_000 {
                refreshGaps.append(gap)
                if refreshGaps.count > 60 { refreshGaps.removeFirst() }
                if refreshGaps.count >= 20 {
                    let sorted = refreshGaps.sorted()
                    refresh = sorted[sorted.count / 2]
                    fixedRefresh = sorted[sorted.count * 9 / 10] - sorted[sorted.count / 10] < 500_000
                }
            }
        }
        lastPresented = max(lastPresented, presented)
        // Learned from frames presented on arrival (random phases), not held ones.
        if deadlineLead == nil, startedAt > 0, presented > startedAt {
            deadlineLeads.append(presented - startedAt)
            if deadlineLeads.count >= 30 {
                let sorted = deadlineLeads.sorted()
                deadlineLead = sorted[sorted.count / 20]
            }
        }
    }
}
