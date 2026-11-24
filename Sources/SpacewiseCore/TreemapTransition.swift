import CoreGraphics

/// How the storage map moves from one finished render to the next. Pure geometry, so the start and end rectangles
/// are tested without a window; the app animates two existing bitmaps between them and never re-renders per frame.
public enum TreemapTransition: Equatable, Sendable {
    /// The new map is a folder drawn in the old one at `from` (old layout coordinates): the old picture grows until
    /// that folder fills the map, while the new picture grows out of the folder's rectangle.
    case zoomIn(from: CGRect)
    /// The old map is a folder drawn in the new one at `to` (new layout coordinates): the old picture shrinks into
    /// that rectangle while the new picture settles from enlarged to its place.
    case zoomOut(to: CGRect)
    /// Same place, new data (a live scan checkpoint, or a zoom that cannot be traced): fade from old to new.
    case crossFade
    /// Same model, new size or appearance: swap without animation.
    case cut

    /// The smallest folder rectangle (in points, each side) a zoom grows from; anything smaller cross-fades.
    public static let minimumZoomSide: CGFloat = 6

    /// The transition between two renders. `sameModel` is true when only the size, scale or appearance changed.
    /// `reduceMotion` turns zooms into cross-fades (Reduce Motion: no movement, cross-fades only).
    public static func between(
        old: TreemapModel, _ oldLayout: TreemapLayout, new: TreemapModel,
        _ newLayout: TreemapLayout, sameModel: Bool, reduceMotion: Bool
    ) -> TreemapTransition {
        if sameModel { return .cut }
        let zoom: TreemapTransition? = {
            guard old.scope != new.scope else { return nil }
            if let scope = new.scope, let tile = old.tileIndex(forNode: scope), oldLayout.rects.indices.contains(tile) {
                let rect = oldLayout.rects[tile]
                return rect.width >= minimumZoomSide && rect.height >= minimumZoomSide ? .zoomIn(from: rect) : nil
            }
            if let scope = old.scope, let tile = new.tileIndex(forNode: scope), newLayout.rects.indices.contains(tile) {
                let rect = newLayout.rects[tile]
                return rect.width >= minimumZoomSide && rect.height >= minimumZoomSide ? .zoomOut(to: rect) : nil
            }
            return nil
        }()
        guard let zoom else { return .crossFade }
        return reduceMotion ? .crossFade : zoom
    }

    /// Where each picture is drawn at the start and the end, and how opaque the picture on top is.
    public struct Geometry: Equatable, Sendable {
        public let outgoingStart: CGRect
        public let outgoingEnd: CGRect
        public let incomingStart: CGRect
        public let incomingEnd: CGRect
        /// True when the new picture is drawn over the old one (it fades in); false when the old one is on top and
        /// fades out.
        public let incomingOnTop: Bool

        /// Both rectangles and the top picture's opacity at `progress` (0...1, already eased).
        public func frame(at progress: CGFloat) -> (outgoing: CGRect, incoming: CGRect, topOpacity: CGFloat) {
            let t = min(1, max(0, progress))
            func mix(_ a: CGRect, _ b: CGRect) -> CGRect {
                CGRect(
                    x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                    width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
            }
            return (mix(outgoingStart, outgoingEnd), mix(incomingStart, incomingEnd), incomingOnTop ? t : 1 - t)
        }
    }

    /// The rectangle `bounds` is stretched to so that `rect` (inside `bounds`) lands exactly on `bounds`.
    public static func enlarged(_ bounds: CGRect, toFill rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return bounds }
        let sx = bounds.width / rect.width
        let sy = bounds.height / rect.height
        return CGRect(
            x: bounds.minX - (rect.minX - bounds.minX) * sx, y: bounds.minY - (rect.minY - bounds.minY) * sy,
            width: bounds.width * sx, height: bounds.height * sy)
    }

    public func geometry(in bounds: CGRect) -> Geometry {
        switch self {
        case .zoomIn(let folder):
            Geometry(
                outgoingStart: bounds, outgoingEnd: Self.enlarged(bounds, toFill: folder),
                incomingStart: folder, incomingEnd: bounds, incomingOnTop: true)
        case .zoomOut(let folder):
            Geometry(
                outgoingStart: bounds, outgoingEnd: folder,
                incomingStart: Self.enlarged(bounds, toFill: folder), incomingEnd: bounds, incomingOnTop: false)
        case .crossFade, .cut:
            Geometry(
                outgoingStart: bounds, outgoingEnd: bounds, incomingStart: bounds, incomingEnd: bounds,
                incomingOnTop: true)
        }
    }

    /// Seconds the transition takes. Zooms are long enough to follow; fades between live checkpoints are shorter so
    /// one always finishes well before the next checkpoint (about once a second).
    public var duration: Double {
        switch self {
        case .zoomIn, .zoomOut: 0.25
        case .crossFade: 0.2
        case .cut: 0
        }
    }

    /// The standard ease-in-ease-out curve (CSS `ease-in-out`, cubic Bézier 0.42, 0, 0.58, 1) at time `t` in 0...1.
    public static func eased(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        // Solve x(s) = t for the curve parameter s by Newton steps, then return y(s).
        func x(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * 0.42 + 3 * (1 - s) * s * s * 0.58 + s * s * s }
        func dx(_ s: Double) -> Double {
            3 * (1 - s) * (1 - s) * 0.42 + 6 * (1 - s) * s * (0.58 - 0.42) + 3 * s * s * (1 - 0.58)
        }
        var s = t
        for _ in 0..<8 {
            let slope = dx(s)
            guard abs(slope) > 1e-9 else { break }
            s = min(1, max(0, s - (x(s) - t) / slope))
        }
        return 3 * (1 - s) * s * s + s * s * s
    }
}
