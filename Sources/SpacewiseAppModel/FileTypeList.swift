import SpacewiseCore

/// One row of the file-type list beside the map: what one colour stands for and how much of the map it covers.
public struct FileTypeRow: Equatable, Sendable {
    public let category: FileCategory
    /// Allocated bytes of the tiles this row lights up when it is highlighted (managed tiles have their own row).
    public let bytes: UInt64
    /// Entries represented by leaf tiles: one per file, package or folder block, plus the entries in each group.
    public let items: Int
    /// Share of the map's area, 0...1. The shares of all rows add up to 1 (the map is fully accounted for).
    public let share: Double
}

/// The file-type list for a map, largest first. Built from the drawn tiles, so it describes the map as shown.
public enum FileTypeList {
    public static func rows(for model: TreemapModel?) -> [FileTypeRow] {
        guard let model, !model.isEmpty else { return [] }
        let legend = model.legend()
        let total = legend.reduce(UInt64(0)) { $0 + $1.weight }
        return legend.map { entry in
            FileTypeRow(
                category: entry.category, bytes: entry.weight, items: entry.tiles,
                share: total > 0 ? Double(entry.weight) / Double(total) : 0)
        }
    }
}

/// The one file type highlighted on the map, if any. The type list and the map both show this value; neither keeps a
/// copy, so clearing it in one place (Esc on the map, Esc or a second click in the list) clears it everywhere.
public struct TypeHighlight: Equatable, Sendable {
    public private(set) var category: FileCategory?

    public init(_ category: FileCategory? = nil) { self.category = category }

    /// Choosing the highlighted type again clears it, as in WinDirStat.
    public mutating func choose(_ chosen: FileCategory?) {
        category = chosen == category ? nil : chosen
    }

    public mutating func clear() { category = nil }

    /// A new map may no longer contain the highlighted type (after zooming, or as a scan grows); drop it then.
    /// Returns true when the highlight changed.
    @discardableResult public mutating func keep(only rows: [FileTypeRow]) -> Bool {
        guard let category, !rows.contains(where: { $0.category == category }) else { return false }
        self.category = nil
        return true
    }
}

/// Whether the next map continues the one on screen (the same scan, so a zoom or a fade between them means something)
/// or replaces it (a new scan, or leaving the results), in which case the new map simply fades in.
public enum MapContinuity {
    public static func continues(from old: ScanPhase, to new: ScanPhase) -> Bool {
        switch (old, new) {
        case (.ready, _), (_, .ready): false
        case (.settled, .scanning), (.settled, .stopping): false  // a new scan starts
        default: true  // same phase, or a scan stopping or settling
        }
    }
}
