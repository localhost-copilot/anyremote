import Foundation

/// How long video waits in the network's queues, estimated on the viewer from
/// each frame's transit (handed to the network on the host → reassembled
/// here, on the synced clock) and reported to the host once a second.
///
/// A link that can't carry the bit rate often loses nothing at first: a
/// router or Wi‑Fi buffer fills and every frame arrives later and later.
/// Loss-based adaptation never sees that, so the delay is measured too. The
/// fastest frame of each second is compared with the fastest of the last
/// minute: a big keyframe takes long to cross on its own, but while a queue
/// stands even the smallest frame waits behind it. A queue that stands from
/// the very start of a session sets the floor too high and isn't seen; loss
/// usually catches that case.
struct QueuingDelay {
    /// Per-report minimum transits, newest last.
    private var history: [Double] = []
    private var current: Double?
    static let historyLength = 60

    mutating func record(transitMilliseconds: Double) {
        current = min(current ?? .infinity, transitMilliseconds)
    }

    /// The queuing delay since the previous call, or nil when no frame arrived.
    mutating func take() -> Double? {
        guard let current else { return nil }
        self.current = nil
        history.append(current)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        return max(0, current - (history.min() ?? current))
    }
}
