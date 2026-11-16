import AnyRemoteMedia
import AnyRemoteWire
import AppKit

/// What one of the other Mac's menu bar items opened that isn't a menu (a
/// popover, a panel), shown below that Mac's icon in this menu bar. Like a
/// popover, it closes when clicked outside; Escape goes to the app there,
/// which closes it itself.
@MainActor
final class PopupWindowController: NSWindowController, RemoteInputSink, RemoteKeyTarget {
    private(set) var stream: StreamDescription
    unowned let connection: HostConnection
    let surface = RemoteSurfaceView()
    private let stats = PipelineStats()
    private var outsideClicks: Any?
    var onClose: (() -> Void)?
    private var closed = false

    init(connection: HostConnection, description: StreamDescription) {
        self.connection = connection
        stream = description
        let panel = PopupPanel(contentRect: NSRect(origin: .zero, size: description.frame.size),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        surface.frame = NSRect(origin: .zero, size: description.frame.size)
        surface.autoresizingMask = [.width, .height]
        surface.sink = self
        surface.frameLayer.stats = stats
        panel.contentView = surface
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var streamID: UInt16 { stream.streamID }

    func start() {
        place()
        let layer = surface.frameLayer
        let shown = Once()
        connection.client.attach(streamID: stream.streamID, stats: stats) { frame in
            layer.enqueue(frame)
            guard shown.claim() else { return }
            // Show on the first frame, so no empty rectangle flashes.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !self.closed else { return }
                    // Typing goes to the popup (a search field), as it would there.
                    NSApp.activate()
                    self.window?.makeKeyAndOrderFront(nil)
                }
            }
        }
        // Like a popover: a click anywhere else closes it.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func place() {
        guard let window else { return }
        let origin = RemoteStatusItems.shared.popupOrigin(for: stream.frame, from: connection)
            ?? NSPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 8)
        window.setFrame(NSRect(x: origin.x, y: origin.y - stream.frame.height,
                               width: stream.frame.width, height: stream.frame.height), display: true)
    }

    func hostFrameChanged(_ frame: CGRect) {
        let resized = frame.size != stream.frame.size
        stream.frame = frame
        if resized { place() }
    }

    /// Closed here: the host closes it too.
    override func close() {
        guard !closed else { return }
        closed = true
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        window?.orderOut(nil)
        onClose?()
    }

    /// Closed on the host (the app closed it).
    func hostEnded() {
        onClose = nil
        connection.client.detach(streamID: stream.streamID, closeOnHost: false)
        close()
    }

    func cursorChanged() { surface.refreshCursor() }

    // MARK: Input

    var remoteCursor: NSCursor? { connection.currentCursor }

    func hostPoint(forScreenPoint point: NSPoint) -> CGPoint {
        guard let window else { return .zero }
        return CGPoint(x: point.x - window.frame.minX, y: window.frame.maxY - point.y)
    }

    func sendInput(_ event: InputEvent) { connection.client.send(.input(streamID: stream.streamID, event)) }
    func pressBegan() {}
    func pressEnded() {}
    func handleWindowShortcut(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool { false }
}

private final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
