import SwiftUI

/// Where each window goes in the All Windows view: like Mission Control,
/// every thumbnail keeps its window's shape, and each one goes into the
/// column that is shortest so far, so the columns stay about level.
///
/// Both the layout and arrow-key navigation use this, so the tile an arrow
/// key reaches is the one on screen in that direction.
struct MasonryPlacement {
    /// Each item's frame: a thumbnail of the item's aspect ratio with a
    /// caption of `captionHeight` below it.
    private(set) var frames: [CGRect] = []
    private(set) var columnOf: [Int] = []
    private(set) var height: CGFloat = 0

    /// Thumbnails never get wider or taller than this, so one panorama or a
    /// tall sidebar window doesn't push everything else aside.
    static let aspectRange: ClosedRange<CGFloat> = 0.6...2.2
    /// Few windows make larger tiles, but not huge ones.
    static let maxColumnWidth: CGFloat = 440

    init(aspects: [CGFloat], columns: Int, width: CGFloat, spacing: CGFloat, captionHeight: CGFloat) {
        guard !aspects.isEmpty, width > 0 else { return }
        let columns = max(1, min(columns, aspects.count))
        let columnWidth = min((width - spacing * CGFloat(columns - 1)) / CGFloat(columns), Self.maxColumnWidth)
        let used = columnWidth * CGFloat(columns) + spacing * CGFloat(columns - 1)
        let left = max(0, (width - used) / 2)
        var bottoms = [CGFloat](repeating: 0, count: columns)
        for aspect in aspects {
            let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] }!
            let thumbnail = columnWidth / Self.aspectRange.clamp(aspect)
            let y = bottoms[column] == 0 ? 0 : bottoms[column] + spacing
            frames.append(CGRect(x: left + CGFloat(column) * (columnWidth + spacing), y: y,
                                 width: columnWidth, height: thumbnail + captionHeight))
            columnOf.append(column)
            bottoms[column] = y + thumbnail + captionHeight
        }
        height = bottoms.max() ?? 0
    }

    enum Direction { case left, right, up, down }

    /// The item an arrow key moves to from `index`: the next one up or down
    /// its column, or the one beside it in the nearest column that has one,
    /// at about the same height.
    func neighbour(of index: Int, _ direction: Direction) -> Int? {
        guard frames.indices.contains(index) else { return nil }
        let frame = frames[index], column = columnOf[index]
        switch direction {
        case .up, .down:
            let sameColumn = frames.indices.filter { columnOf[$0] == column }
            guard let position = sameColumn.firstIndex(of: index) else { return nil }
            let next = position + (direction == .down ? 1 : -1)
            return sameColumn.indices.contains(next) ? sameColumn[next] : nil
        case .left, .right:
            let columns = Set(columnOf)
            let candidates = columns.filter { direction == .right ? $0 > column : $0 < column }
            guard let target = direction == .right ? candidates.min() : candidates.max() else { return nil }
            return frames.indices.filter { columnOf[$0] == target }
                .min { abs(frames[$0].midY - frame.midY) < abs(frames[$1].midY - frame.midY) }
        }
    }
}

/// Lays its subviews out by `MasonryPlacement`, one per aspect ratio, in order.
struct MasonryLayout: Layout {
    var aspects: [CGFloat]
    var columns: Int
    var spacing: CGFloat
    var captionHeight: CGFloat

    private func placement(width: CGFloat) -> MasonryPlacement {
        MasonryPlacement(aspects: aspects, columns: columns, width: width, spacing: spacing,
                         captionHeight: captionHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        return CGSize(width: width, height: placement(width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = placement(width: bounds.width).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
}

private extension ClosedRange where Bound == CGFloat {
    func clamp(_ value: CGFloat) -> CGFloat {
        value.isFinite ? Swift.min(Swift.max(value, lowerBound), upperBound) : 1
    }
}
