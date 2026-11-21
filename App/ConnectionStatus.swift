import AnyRemoteMedia
import AnyRemoteWire
import AppKit

/// How a stream's connection is doing, for the Remote menu, and a small
/// banner that appears only while it is slow.
///
/// Quiet by design: a good connection shows nothing over the remote window.
/// The banner waits for a few slow seconds in a row before it appears and
/// for several good ones before it goes, so a single hiccup doesn't flash it.
@MainActor
final class ConnectionStatus {
    /// Estimated delay from the host's screen to this one, in milliseconds.
    private(set) var latency: Double?
    private(set) var framesPerSecond: Double = 0
    private(set) var isSlow = false
    /// Frames are being lost (rather than arriving late).
    private var isLossy = false
    private var slowSeconds = 0
    private var goodSeconds = 0
    private var relayed = false
    private var banner: NSView?
    private var bannerLabel: NSTextField?

    static let slowLatency: Double = 80
    static let slowDroppedFrames = 3
    private static let secondsToShow = 3
    private static let secondsToHide = 5

    /// The Remote menu's line, e.g. "12 ms · 60 fps".
    var summary: String? {
        guard let latency else { return nil }
        return String(format: String(localized: "Latency %lld ms · %lld fps"),
                      Int(latency.rounded()), Int(framesPerSecond.rounded()))
    }

    /// Called once a second with the latest statistics.
    /// `relayed`: through a Tailscale relay, which the banner then names as
    /// the likely reason.
    func update(viewer: PipelineStats.Summary, host: HostStreamReport?, roundTrip: Double?, relayed: Bool = false,
                in content: NSView) {
        self.relayed = relayed
        latency = Self.latency(viewer: viewer, host: host, roundTrip: roundTrip)
        framesPerSecond = viewer.framesPerSecond
        let late = (latency ?? 0) > Self.slowLatency
        let lossy = viewer.droppedFrames >= Self.slowDroppedFrames
        let slow = late || lossy
        if slow { isLossy = lossy && !late }
        if slow {
            slowSeconds += 1
            goodSeconds = 0
        } else {
            goodSeconds += 1
            slowSeconds = 0
        }
        if !isSlow, slowSeconds >= Self.secondsToShow {
            isSlow = true
        } else if isSlow, goodSeconds >= Self.secondsToHide {
            isSlow = false
        }
        showBanner(isSlow, in: content)
    }

    /// Host queueing and encoding, half the round trip, then decoding and
    /// presenting here. An idle window sends no frames; then only the network counts.
    static func latency(viewer: PipelineStats.Summary, host: HostStreamReport?, roundTrip: Double?) -> Double? {
        guard let roundTrip else { return nil }
        var total = roundTrip / 2
        if let host { total += host.waitP50 + host.encodeP50 }
        total += (viewer.p50[.decode] ?? 0) + (viewer.p50[.present] ?? 0)
        return total
    }

    private func showBanner(_ show: Bool, in content: NSView) {
        if show {
            var text = isLossy ? String(localized: "Unstable connection")
                : String(format: String(localized: "Slow connection · %lld ms"), Int((latency ?? 0).rounded()))
            if relayed { text += " · " + String(localized: "via a Tailscale relay") }
            if let bannerLabel {
                bannerLabel.stringValue = text
                return
            }
            let (view, label) = Self.makeBanner(text: text)
            view.alphaValue = 0
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
                view.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -24),
            ])
            banner = view
            bannerLabel = label
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                view.animator().alphaValue = 1
            }
        } else if let banner {
            self.banner = nil
            bannerLabel = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                banner.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { banner.removeFromSuperview() } })
        }
    }

    private static func makeBanner(text: String) -> (NSView, NSTextField) {
        let icon = NSImageView(image: NSImage(systemSymbolName: "wifi.exclamationmark",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.contentTintColor = .systemYellow
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let background = PassThroughEffectView()
        background.material = .hudWindow
        background.appearance = NSAppearance(named: .vibrantDark)
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 13
        background.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            background.heightAnchor.constraint(equalToConstant: 26),
        ])
        return (background, label)
    }
}

/// Lets clicks through to the remote window underneath.
private final class PassThroughEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
