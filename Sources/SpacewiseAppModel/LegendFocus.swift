import SpacewiseCore

/// Which map tiles stay lit while one legend entry is focused.
public enum LegendFocus {
    /// A type matches individually drawn, non-managed tiles of that type, and blocks or groups tinted by it;
    /// the managed row matches every managed tile. Managed tiles are counted once, under their own legend row.
    public static func matches(_ tile: TreemapTile, _ category: FileCategory) -> Bool {
        if category == .managedZone { return tile.managed }
        if tile.managed { return false }
        return tile.category == category || tile.tint == category
    }
}
