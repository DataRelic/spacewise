import Foundation

// Storage-map data model. Pure, Sendable and bounded: a TreemapModel never holds more than
// `TreemapLimits.maxTiles` tiles no matter how large the scan is, and it is built from either the settled
// sorted index or the scanner's provisional index through one algorithm (TreemapBuilder), so the two cannot
// drift. Area is allocated size. Unknown, denied and not-yet-read items have no area; they are never "zero".

public struct TreemapLimits: Sendable {
    /// Hard cap on tiles (files, packages, folders, blocks, aggregates and the root).
    public var maxTiles = 8000
    /// Children inspected per folder (a single folder may use the whole tile budget); the rest are summed into one
    /// aggregate.
    public var maxPerFolder = 4096
    /// Provisional-index child visits per build. Bounds main-path scan cost at checkpoints.
    public var maxCost = 1_500_000
    public init(maxTiles: Int = 8000, maxPerFolder: Int = 4096, maxCost: Int = 1_500_000) {
        self.maxTiles = max(2, maxTiles)
        self.maxPerFolder = max(1, maxPerFolder)
        self.maxCost = max(0, maxCost)
    }
    public static let standard = TreemapLimits()
    /// Live (provisional) maps are rebuilt about once a second on the scanner worker; keep them smaller.
    public static let live = TreemapLimits(maxTiles: 4000)
}

public struct TreemapTile: Sendable {
    public enum Kind: UInt8, Sendable {
        /// A folder whose contents are drawn (individually and/or in an aggregate) inside it.
        case folder
        /// A folder drawn as one block because it was not expanded.
        case folderBlock
        /// A package (app bundle and similar) treated as one item, as Finder does.
        case package
        case file
        /// "N smaller items": several items summed. Selectable; never counted twice.
        case aggregate
    }
    /// Scan node ID, or -1 for aggregates and the virtual top-level root.
    public let nodeID: Int
    /// Parent tile index, -1 for the root.
    public let parent: Int
    public let kind: Kind
    public let category: FileCategory
    /// Allocated bytes this tile's area stands for. A folder's weight equals the sum of its child tiles.
    public let weight: UInt64
    public let depth: Int
    public let firstChild: Int
    public let childCount: Int
    /// True when the weight is a lower bound (partly measured, unreadable contents or still being read).
    public let partial: Bool
    /// For aggregates: how many items were summed (including items with no allocated size).
    public let itemCount: Int
    /// Inside the system-managed group (unified drive view only). Classification, independent of file type.
    public let managed: Bool
    /// For blocks and summed groups only: the main file type among their largest known items. An estimate used for
    /// colour; the legend never counts it as type bytes.
    public let tint: FileCategory?
    public var isLeaf: Bool { childCount == 0 }
    public var children: Range<Int> { firstChild..<(firstChild + childCount) }
}

public struct TreemapStats: Sendable, Equatable {
    /// Files, packages and folders that have their own tile (the root excluded).
    public var itemsDrawn = 0
    public var folders = 0
    public var collapsedFolders = 0
    public var aggregates = 0
    /// Items summed inside aggregate tiles.
    public var itemsGrouped = 0
    /// Items with no allocated size inside expanded folders: not drawn, not hidden bytes.
    public var itemsWithoutSize = 0
    public var partialTiles = 0
    /// True when the tile, per-folder or cost limits cut expansion short.
    public var limited = false
    public var cost = 0
    /// Wall time of the build itself, for benchmarks.
    public var buildSeconds = 0.0
}

public struct TreemapModel: Sendable {
    public let scope: Int?
    public let provisional: Bool
    public let tiles: [TreemapTile]
    /// Parallel to `tiles`; nil for aggregates and the virtual top-level root.
    public let rows: [ScopeRow?]
    public let stats: TreemapStats
    private let tileByNode: [Int: Int]

    init(scope: Int?, provisional: Bool, tiles: [TreemapTile], rows: [ScopeRow?], stats: TreemapStats) {
        self.scope = scope
        self.provisional = provisional
        self.tiles = tiles
        self.rows = rows
        self.stats = stats
        var map: [Int: Int] = [:]
        for (index, tile) in tiles.enumerated() where tile.nodeID >= 0 && index > 0 { map[tile.nodeID] = index }
        tileByNode = map
    }
    public var rootWeight: UInt64 { tiles.first?.weight ?? 0 }
    public var isEmpty: Bool { tiles.count <= 1 }
    public func tileIndex(forNode id: Int) -> Int? { tileByNode[id] }

    /// The tile that should be highlighted for a scan node: its own tile, or when the node is not drawn the
    /// smallest drawn ancestor (its aggregate when that ancestor is an expanded folder). `parentOf` walks the scan
    /// tree.
    public func nearestTile(forNode id: Int, parentOf: (Int) -> Int?) -> Int? {
        func aggregate(under tile: Int) -> Int? { tiles[tile].children.first { tiles[$0].kind == .aggregate } }
        var cursor: Int? = id
        var hops = 0
        while let node = cursor, hops < 100_000 {
            if node == scope { return aggregate(under: 0) }
            if let index = tileByNode[node] {
                if node == id { return index }
                return tiles[index].kind == .folder ? (aggregate(under: index) ?? index) : index
            }
            cursor = parentOf(node)
            hops += 1
        }
        return scope == nil && cursor == nil ? aggregate(under: 0) : nil
    }

    /// The scan node of the ancestor tile directly under the scope root: the row that represents `tile` in the list.
    public func scopeLevelNode(of tile: Int) -> Int? {
        guard tiles.indices.contains(tile), tile != 0 else { return nil }
        var cursor = tile
        while tiles[cursor].parent > 0 { cursor = tiles[cursor].parent }
        let id = tiles[cursor].nodeID
        return id >= 0 ? id : nil
    }

    /// Bytes and tile counts per category over drawn leaf tiles. Honest scope: this is the map, not the whole scan.
    public func legend() -> [(category: FileCategory, weight: UInt64, tiles: Int)] {
        var weights = [UInt64](repeating: 0, count: FileCategory.allCases.count)
        var counts = [Int](repeating: 0, count: FileCategory.allCases.count)
        for tile in tiles.dropFirst() where tile.isLeaf {
            // Managed leaves are counted once, in their own row, so the legend adds up.
            let key = tile.managed ? FileCategory.managedZone.rawValue : tile.category.rawValue
            weights[key] += tile.weight
            counts[key] += tile.kind == .aggregate ? tile.itemCount : 1
        }
        return FileCategory.allCases.compactMap { category in
            counts[category.rawValue] > 0 ? (category, weights[category.rawValue], counts[category.rawValue]) : nil
        }.sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.category.rawValue < $1.category.rawValue }
    }
}
