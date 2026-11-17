import AnyRemoteWire
import CoreGraphics

/// The host's windows as the picker shows them while it is on screen.
///
/// The host lists windows front to back, and that order changes whenever a
/// window there comes forward, which using one of its mirrors here does
/// too. Following it would shuffle the grid every few seconds although
/// nothing in it changed, so the list keeps the order it had: windows that
/// close drop out, and a new window goes in front of its app's others (or
/// first of all, for an app that had none), so app groups stay where they
/// were. The front-to-back order is taken again with `reset`, when the
/// picker isn't visible.
///
/// Shapes are kept too: a thumbnail only takes a window's new aspect ratio
/// once it differs by more than `aspectTolerance`, so a window resized a
/// little doesn't send the windows after it into other columns.
public struct StableWindowList: Equatable, Sendable {
    public private(set) var windows: [WindowSummary] = []
    private var aspects: [UInt32: CGFloat] = [:]

    public static let aspectTolerance: CGFloat = 0.1

    public init(_ windows: [WindowSummary] = []) { reset(to: windows) }

    /// Takes the host's order as it is.
    public mutating func reset(to listing: [WindowSummary]) {
        windows = listing
        aspects = Dictionary(listing.map { ($0.windowID, Self.aspect(of: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Takes the host's latest list, keeping the order and shapes shown.
    public mutating func update(with listing: [WindowSummary]) {
        let fresh = Dictionary(listing.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        var result = windows.compactMap { fresh[$0.windowID] }
        let known = Set(result.map(\.windowID))
        // Back to front, so windows new together keep their own order
        // in front of their app's older ones.
        for window in listing.reversed() where !known.contains(window.windowID) {
            let index = result.firstIndex { Self.sameApplication($0, window) } ?? 0
            result.insert(window, at: index)
        }
        windows = result
        var kept: [UInt32: CGFloat] = [:]
        for window in result {
            let current = Self.aspect(of: window)
            if let shown = aspects[window.windowID], abs(current / shown - 1) <= Self.aspectTolerance {
                kept[window.windowID] = shown
            } else {
                kept[window.windowID] = current
            }
        }
        aspects = kept
    }

    /// The width-to-height ratio the window's thumbnail is laid out with.
    public func aspect(of window: WindowSummary) -> CGFloat {
        aspects[window.windowID] ?? Self.aspect(of: window)
    }

    private static func aspect(of window: WindowSummary) -> CGFloat {
        window.frame.height > 0 ? window.frame.width / window.frame.height : 1
    }

    private static func sameApplication(_ a: WindowSummary, _ b: WindowSummary) -> Bool {
        (a.bundleIdentifier ?? a.applicationName) == (b.bundleIdentifier ?? b.applicationName)
    }
}
