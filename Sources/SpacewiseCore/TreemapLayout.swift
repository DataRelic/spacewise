import CoreGraphics
import Foundation

/// Squarified layout of a TreemapModel. Coordinates are y-down (a flipped view / image rows top to bottom).
/// Every child rectangle lies inside its parent's, children tile their parent exactly (no gaps, no overlap), and
/// each child's area is proportional to its weight within the parent. Pure and O(tiles).
public struct TreemapLayout: Sendable {
    public let bounds: CGRect
    /// Parallel to `TreemapModel.tiles`.
    public let rects: [CGRect]

    public static func compute(_ model: TreemapModel, in bounds: CGRect) -> TreemapLayout {
        var rects = [CGRect](repeating: .zero, count: model.tiles.count)
        guard !model.tiles.isEmpty else { return TreemapLayout(bounds: bounds, rects: rects) }
        rects[0] = bounds
        for (index, tile) in model.tiles.enumerated() where tile.childCount > 0 {
            let kids = tile.children
            let placed = squarify(kids.map { Double(model.tiles[$0].weight) }, in: rects[index])
            for (offset, child) in kids.enumerated() { rects[child] = placed[offset] }
        }
        return TreemapLayout(bounds: bounds, rects: rects)
    }

    /// The same layout stretched by `x` and `y` (a map rendered for one size, shown at another).
    public func scaled(x: CGFloat, y: CGFloat) -> TreemapLayout {
        func scale(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * x, y: rect.minY * y, width: rect.width * x, height: rect.height * y)
        }
        return TreemapLayout(bounds: scale(bounds), rects: rects.map(scale))
    }

    /// Bruls–Huizing–van Wijk squarified layout. `weights` must be sorted descending; zero weights get empty rects.
    static func squarify(_ weights: [Double], in rect: CGRect) -> [CGRect] {
        var out = [CGRect](repeating: CGRect(x: rect.minX, y: rect.minY, width: 0, height: 0), count: weights.count)
        let total = weights.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return out }
        let scale = Double(rect.width) * Double(rect.height) / total
        var remaining = rect
        var start = 0
        func worst(_ range: Range<Int>, side: Double) -> Double {
            var sum = 0.0
            var high = 0.0
            var low = Double.greatestFiniteMagnitude
            for index in range {
                let area = weights[index] * scale
                sum += area
                high = max(high, area)
                low = min(low, area)
            }
            guard sum > 0, low > 0 else { return Double.greatestFiniteMagnitude }
            return max(side * side * high / (sum * sum), sum * sum / (side * side * low))
        }
        while start < weights.count, weights[start] > 0 {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else { break }
            var end = start + 1
            var current = worst(start..<end, side: side)
            while end < weights.count, weights[end] > 0 {
                let next = worst(start..<(end + 1), side: side)
                if next > current { break }
                current = next
                end += 1
            }
            let lastRow = end >= weights.count || weights[end] <= 0
            let rowArea = weights[start..<end].reduce(0) { $0 + $1 * scale }
            let vertical = remaining.width >= remaining.height  // strip along the left edge
            let span = Double(vertical ? remaining.height : remaining.width)
            var thickness = rowArea / span
            if lastRow { thickness = Double(vertical ? remaining.width : remaining.height) }
            var cursor = Double(vertical ? remaining.minY : remaining.minX)
            let stripEnd = Double(vertical ? remaining.maxY : remaining.maxX)
            for index in start..<end {
                let length = index == end - 1 ? stripEnd - cursor : weights[index] * scale / thickness
                out[index] =
                    vertical
                    ? CGRect(x: remaining.minX, y: cursor, width: thickness, height: length)
                    : CGRect(x: cursor, y: remaining.minY, width: length, height: thickness)
                cursor += length
            }
            remaining =
                vertical
                ? CGRect(
                    x: remaining.minX + thickness, y: remaining.minY,
                    width: max(0, remaining.width - thickness), height: remaining.height)
                : CGRect(
                    x: remaining.minX, y: remaining.minY + thickness,
                    width: remaining.width, height: max(0, remaining.height - thickness))
            start = end
        }
        return out
    }

    /// Deepest tile whose rectangle contains `point`, or nil outside the map. O(depth × siblings).
    public func hit(_ point: CGPoint, in model: TreemapModel) -> Int? {
        guard !rects.isEmpty, rects[0].contains(point) else { return nil }
        var current = 0
        descend: while true {
            for child in model.tiles[current].children where rects[child].contains(point) {
                current = child
                continue descend
            }
            return current
        }
    }

    public enum Direction: Sendable { case left, right, up, down }
    /// The neighbouring leaf tile in a direction, preferring tiles that overlap the current one on the cross axis.
    public func neighbor(of tile: Int, _ direction: Direction, in model: TreemapModel) -> Int? {
        guard model.tiles.indices.contains(tile) else { return nil }
        let from = rects[tile]
        var best: (index: Int, score: CGFloat)?
        for (index, candidate) in model.tiles.enumerated() where index != tile && index != 0 && candidate.isLeaf {
            let rect = rects[index]
            guard rect.width >= 1, rect.height >= 1 else { continue }
            let gap: CGFloat
            let cross: CGFloat
            switch direction {
            case .right:
                gap = rect.minX - from.maxX
                cross = abs(rect.midY - from.midY)
            case .left:
                gap = from.minX - rect.maxX
                cross = abs(rect.midY - from.midY)
            case .down:
                gap = rect.minY - from.maxY
                cross = abs(rect.midX - from.midX)
            case .up:
                gap = from.minY - rect.maxY
                cross = abs(rect.midX - from.midX)
            }
            guard gap >= -0.5 else { continue }
            let overlaps: Bool
            switch direction {
            case .left, .right: overlaps = rect.minY < from.maxY && rect.maxY > from.minY
            case .up, .down: overlaps = rect.minX < from.maxX && rect.maxX > from.minX
            }
            let score = max(0, gap) + cross * (overlaps ? 0.25 : 3)
            if best == nil || score < best!.score || (score == best!.score && index < best!.index) {
                best = (index, score)
            }
        }
        return best?.index
    }
}
