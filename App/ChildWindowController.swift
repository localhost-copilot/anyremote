import AnyRemoteMedia
import AnyRemoteWire
import AppKit

/// Shows a host child window (menu, popover, sheet, tooltip, panel) as a
/// borderless, transparent child of its mirror, at the same offset from the
/// opened window as on the host.
@MainActor
final class ChildWindowController: NSObject, RemoteInputSink {
    private(set) var stream: StreamDescription
    unowned let connection: HostConnection
    weak var parent: MirrorWindowController?
    let parentStreamID: UInt16
    private let window: ChildPanel
    private let surface = RemoteSurfaceView()
    private let stats = PipelineStats()

    init(connection: HostConnection, description: StreamDescription, parent: MirrorWindowController) {
        self.connection = connection
        self.stream = description
        self.parent = parent
        self.parentStreamID = parent.streamID
        window = ChildPanel(contentRect: NSRect(origin: .zero, size: stream.frame.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        // The captured image carries the host's shadow-less window; draw ours
        // for menus and popups. Input method windows (far higher layers) are
        // mostly transparent around what they show, and a shadow would trace
        // their whole rectangle.
        window.hasShadow = stream.layer > 0 && stream.layer < 1000
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        surface.frame = NSRect(origin: .zero, size: stream.frame.size)
        surface.autoresizingMask = [.width, .height]
        surface.sink = self
        surface.frameLayer.stats = stats
        window.contentView = surface
    }

    func start() {
        reposition()
        let layer = surface.frameLayer
        let window = window
        let shown = Once()
        connection.client.attach(streamID: stream.streamID, stats: stats) { frame in
            layer.enqueue(frame)
            guard shown.claim() else { return }
            // Show on the first frame, so no empty rectangle flashes.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard window.parent == nil, let parentWindow = self.parent?.window else { return }
                    parentWindow.addChildWindow(window, ordered: .above)
                    window.orderFront(nil)
                }
            }
        }
    }

    func hostFrameChanged(_ frame: CGRect) {
        stream.frame = frame
        reposition()
    }

    func reposition() {
        guard let parent else { return }
        window.setFrame(parent.localScreenFrame(forHostFrame: stream.frame), display: true)
    }

    func cursorChanged() { surface.refreshCursor() }

    func close() {
        connection.client.detach(streamID: stream.streamID, closeOnHost: false)
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }

    // Input lands on the opened window's coordinate space.
    var remoteCursor: NSCursor? { connection.currentCursor }
    func hostPoint(forScreenPoint point: NSPoint) -> CGPoint { parent?.hostPoint(forScreenPoint: point) ?? .zero }
    func sendInput(_ event: InputEvent) { parent?.sendInput(event) }
    func pressBegan() { parent?.pressBegan() }
    func pressEnded() { parent?.pressEnded() }
}

final class ChildPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Once: @unchecked Sendable {
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
