import SpacewiseCore

/// The message the storage map shows instead of tiles, when it has none to draw.
public enum MapMessage {
    /// Nil on the Ready screen and whenever the map has tiles.
    public static func make(phase: ScanPhase, model: TreemapModel?, isLive: Bool) -> EmptyScope? {
        guard phase != .ready else { return nil }
        let copy = ProductCopy.Map.self
        guard let model else {
            return isLive
                ? EmptyScope(symbol: "clock", title: copy.waitingTitle, detail: copy.waitingDetail)
                : EmptyScope(symbol: "square.grid.2x2", title: copy.buildingTitle, detail: copy.buildingDetail)
        }
        guard model.isEmpty else { return nil }
        return model.provisional
            ? EmptyScope(symbol: "clock", title: copy.nothingSizedTitle, detail: copy.nothingSizedDetail)
            : EmptyScope(symbol: "square.dashed", title: copy.nothingToDrawTitle, detail: copy.nothingToDrawDetail)
    }
}
