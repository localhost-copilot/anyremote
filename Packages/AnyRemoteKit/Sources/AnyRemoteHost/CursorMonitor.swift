import AnyRemoteWire
import AppKit
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Cursor")

/// Watches the host's system cursor and reports image changes.
///
/// The window server bumps a seed whenever the cursor image changes; polling
/// that integer at display rate is nearly free, and the image itself is only
/// read (on the main thread) when the seed moves. The viewer draws the
/// cursor locally, so pointer motion has no network latency.
final class CursorMonitor: @unchecked Sendable {
    private typealias SeedFunction = @convention(c) () -> Int32
    private static let seedFunction: SeedFunction? = {
        for name in ["CGSCurrentCursorSeed", "SLSCurrentCursorSeed"] {
            if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
                return unsafeBitCast(symbol, to: SeedFunction.self)
            }
        }
        return nil
    }()

    private let queue = DispatchQueue(label: "anyremote.cursor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var lastSeed: Int32 = .min
    private let onChange: @Sendable (CursorImage) -> Void

    init(onChange: @escaping @Sendable (CursorImage) -> Void) {
        self.onChange = onChange
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Sends the current image again (e.g. to a new viewer).
    func resend() {
        queue.async { self.lastSeed = .min }
    }

    private func poll() {
        // Without the seed SPI, sample the image at a low rate instead.
        let seed = Self.seedFunction?() ?? Int32(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 4))
        guard seed != lastSeed else { return }
        lastSeed = seed
        DispatchQueue.main.async { [onChange] in
            guard let image = Self.currentImage(seed: UInt32(bitPattern: seed)) else { return }
            onChange(image)
        }
    }

    @MainActor
    private static func currentImage(seed: UInt32) -> CursorImage? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        let image = cursor.image
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        // The 2x representation keeps the cursor sharp on Retina viewers.
        var rect = CGRect(origin: .zero, size: CGSize(width: size.width * 2, height: size.height * 2))
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let png = HostWindows.encode(cgImage, type: .png) else { return nil }
        return CursorImage(seed: seed, png: png, pointSize: size, hotSpot: cursor.hotSpot)
    }
}
