import AppKit

/// This window's own close, minimize and zoom buttons, shown where the host
/// window has its buttons.
///
/// The host's buttons can't be shown: macOS covers a captured window's
/// buttons with its sharing indicator (the host paints that over, see
/// `SharingIndicatorConcealer`). The window's real buttons are moved out of
/// its hidden title bar into this view, so they look and behave natively:
/// symbols on hover, gray while inactive, ⌥ on zoom, the tiling menu on the
/// green button.
final class WindowButtonGroup: NSView {
    private static let hoverMargin: CGFloat = 4
    private static let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private var buttons: [NSWindow.ButtonType: NSButton] = [:]
    private var tracking: NSTrackingArea?
    private(set) var isMouseInside = false
    /// Called when the pointer leaves the buttons.
    var onMouseExit: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Takes the window's buttons (again: full screen transitions may put
    /// them back into the title bar).
    func adoptButtons(of window: NSWindow) {
        for type in Self.types {
            guard let button = window.standardWindowButton(type) else { continue }
            buttons[type] = button
            if button.superview !== self {
                button.removeFromSuperview()
                addSubview(button)
            }
        }
    }

    func setAction(_ action: Selector, target: AnyObject, for type: NSWindow.ButtonType) {
        buttons[type]?.target = target
        buttons[type]?.action = action
    }

    /// Centers each button on the given point (in the superview's
    /// coordinates); a button without one is hidden.
    func place(centers: [NSWindow.ButtonType: CGPoint]) {
        let shown = Self.types.compactMap { type -> (NSButton, CGPoint)? in
            guard let button = buttons[type], let center = centers[type] else {
                buttons[type]?.isHidden = true
                return nil
            }
            button.isHidden = false
            return (button, center)
        }
        guard !shown.isEmpty else {
            isHidden = true
            return
        }
        let frames = shown.map { button, center in
            let size = button.frame.size
            return NSRect(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded(),
                          width: size.width, height: size.height)
        }
        // Like the title bar's own group, hovering a little around the
        // buttons already shows their symbols.
        let union = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
            .insetBy(dx: -Self.hoverMargin, dy: -Self.hoverMargin)
        frame = union
        for ((button, _), buttonFrame) in zip(shown, frames) {
            button.setFrameOrigin(NSPoint(x: buttonFrame.minX - union.minX, y: buttonFrame.minY - union.minY))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        setMouseInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        // Telling the frame view re-creates tracking areas, which sends an
        // exit although the pointer is still here.
        guard let window else { return }
        let location = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard !bounds.contains(location) else { return }
        setMouseInside(false)
        onMouseExit?()
    }

    /// The buttons show their symbols while the window's frame view (the
    /// private NSThemeFrame, which the buttons ask through `_mouseInGroup:`)
    /// believes the pointer is over its left button group. Its own tracking
    /// area sits in the hidden title bar, so it is told here.
    private func setMouseInside(_ inside: Bool) {
        guard inside != isMouseInside else { return }
        isMouseInside = inside
        let selector = NSSelectorFromString("_setMouseEnteredGroup:entered:")
        if let frameView = window?.contentView?.superview, frameView.responds(to: selector) {
            typealias SetEntered = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
            // The first argument picks the left group (the window buttons).
            unsafeBitCast(frameView.method(for: selector), to: SetEntered.self)(frameView, selector, true, inside)
        }
        for button in buttons.values { button.needsDisplay = true }
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    // Clicks between the buttons stay here: on the host they would land on
    // the sharing indicator, which opens the system's sharing controls there.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
