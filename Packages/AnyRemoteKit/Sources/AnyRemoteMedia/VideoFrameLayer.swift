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

final class NV24MetalContext: @unchecked Sendable {
    static let shared = NV24MetalContext()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let alphaPipeline: MTLRenderPipelineState
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
        var cache: CVMetalTextureCache?
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let areaPipeline = try? device.makeRenderPipelineState(descriptor: areaDescriptor),
              let alphaPipeline = try? device.makeRenderPipelineState(descriptor: alphaDescriptor),
              CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.alphaPipeline = alphaPipeline
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

/// Presents decoded frames as soon as they arrive (latest wins): `444f`, or
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
    private var pending: DecodedFrame?
    private var inFlight = false
    private var lastGeometry: (Int, Int, Int) = (0, 0, 0)
    private var lastFrame: DecodedFrame?
    private var targetSize: CGSize?

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

    /// Thread-safe.
    public func enqueue(_ frame: DecodedFrame) {
        lock.lock()
        if inFlight {
            pending = frame
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()
        renderQueue.async { self.render(frame) }
    }

    /// Redraws the most recent frame, e.g. after the layer was resized.
    public func redrawLastFrame() {
        lock.lock()
        let frame = lastFrame
        lock.unlock()
        if let frame { enqueue(frame) }
    }

    private func finish() {
        lock.lock()
        let next = pending
        pending = nil
        if next == nil { inFlight = false }
        lock.unlock()
        if let next { renderQueue.async { self.render(next) } }
    }

    private func render(_ frame: DecodedFrame) {
        guard let context = NV24MetalContext.shared else { return finish() }
        let width = frame.pixelWidth
        let height = frame.pixelHeight
        if frame.hasAlpha == isOpaque {
            isOpaque = !frame.hasAlpha
        }
        // Scaled here (desktops): the drawable takes the view's pixel size.
        var viewport: MTLViewport?
        var area: (footprint: SIMD2<Float>, taps: Int32)?
        if !frame.hasAlpha, let target = targetPixelSize, target.width >= 2, target.height >= 2 {
            let target = CGSize(width: target.width.rounded(), height: target.height.rounded())
            if drawableSize != target { drawableSize = target }
            let factor = min(target.width / CGFloat(width), target.height / CGFloat(height))
            let size = CGSize(width: (CGFloat(width) * factor).rounded(), height: (CGFloat(height) * factor).rounded())
            viewport = MTLViewport(originX: Double(((target.width - size.width) / 2).rounded()),
                                   originY: Double(((target.height - size.height) / 2).rounded()),
                                   width: Double(size.width), height: Double(size.height), znear: 0, zfar: 1)
            // Source texels per output pixel, in texture coordinates.
            let taps = Int32(min(6, max(1, (1 / factor).rounded(.up))))
            area = (SIMD2(Float(1 / size.width), Float(1 / size.height)), taps)
        } else if drawableSize.width != CGFloat(width) || drawableSize.height != CGFloat(height) {
            drawableSize = CGSize(width: width, height: height)
        }
        var textures: [CVMetalTexture] = []
        if frame.hasAlpha {
            guard let image = makeTexture(context, frame.pixelBuffer, plane: 0, format: .bgra8Unorm,
                                          planar: false) else { return finish() }
            textures = [image]
        } else {
            guard CVPixelBufferGetPlaneCount(frame.pixelBuffer) == 2,
                  let luma = makeTexture(context, frame.pixelBuffer, plane: 0, format: .r8Unorm),
                  let chroma = makeTexture(context, frame.pixelBuffer, plane: 1, format: .rg8Unorm)
            else { return finish() }
            textures = [luma, chroma]
        }
        let metalTextures = textures.compactMap { CVMetalTextureGetTexture($0) }
        guard metalTextures.count == textures.count,
              let drawable = nextDrawable(),
              let commandBuffer = context.commandQueue.makeCommandBuffer() else { return finish() }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        let letterboxed = viewport.map { $0.width < Double(drawable.texture.width) || $0.height < Double(drawable.texture.height) } ?? false
        pass.colorAttachments[0].loadAction = letterboxed ? .clear : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return finish() }
        if let viewport { encoder.setViewport(viewport) }
        if let area {
            encoder.setRenderPipelineState(context.areaPipeline)
            var parameters = AreaParameters(footprint: area.footprint, taps: area.taps)
            encoder.setFragmentBytes(&parameters, length: MemoryLayout<AreaParameters>.stride, index: 0)
        } else {
            encoder.setRenderPipelineState(frame.hasAlpha ? context.alphaPipeline : context.pipeline)
        }
        for (index, texture) in metalTextures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
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
                stats?.record(.present, from: frame.decodedTimeNanos, to: presented)
                if let captured = remoteClock?.localTime(fromSender: frame.captureTimeNanos) {
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
        lastFrame = frame
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
