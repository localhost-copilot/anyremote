import AppKit

/// A window that scrolls dense text by a few points every display refresh:
/// a reproducible, worst-case workload for latency comparisons. With
/// `scrolls` false it shows the same text standing still, like a window
/// that is open but not in use.
@MainActor
public enum SyntheticWorkloadWindow {
    public static func open(size: CGSize, origin: CGPoint = CGPoint(x: 40, y: 40),
                            scrolls: Bool = true) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "AnyRemote synthetic workload"
        window.isReleasedWhenClosed = false
        let view = ScrollingTextView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.orderFrontRegardless()
        if scrolls { view.startScrolling() }
        return window
    }
}

final class ScrollingTextView: NSView {
    private var offset: CGFloat = 0
    private var link: CADisplayLink?
    private let line = String(repeating: "The quick brown fox jumps over the lazy dog 0123456789 — ", count: 6)
    private let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor.textColor,
    ]

    override var isFlipped: Bool { true }

    func startScrolling() {
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        offset = (offset + 3).truncatingRemainder(dividingBy: 18 * 40)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        var y = -offset
        var index = 0
        while y < bounds.height {
            ("\(index) " + line as NSString).draw(at: NSPoint(x: 8, y: y), withAttributes: attributes)
            y += 18
            index += 1
        }
    }
}
