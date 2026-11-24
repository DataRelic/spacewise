import SpacewiseCore

extension ScanResult {
    /// Logical scopes and unfinished physical indexes may need ordering. Small folders can be ordered immediately.
    package func needsBackgroundRowSort(parent: Int?) -> Bool {
        !logicalChildrenAreRanked(of: parent) && logicalChildCount(of: parent) > ScopeSnapshot.pageSize
    }
}

/// The rows the item list shows, resolved lazily: a bounded snapshot while scanning, the shared indexed slice once
/// settled. Indexes are list positions, starting at 0.
@MainActor public protocol RowSource: AnyObject {
    var count: Int { get }
    /// The row at a list position, or nil when the position is outside the list.
    func row(at index: Int) -> ScopeRow?
    /// The list position of a node, or nil when the node is not listed here.
    func index(ofNode id: Int) -> Int?
    /// The node at a list position, without building the full row (filtering and sorting read only names and sizes).
    func node(at index: Int) -> ScanNode?
}

extension RowSource {
    public func node(at index: Int) -> ScanNode? { row(at: index)?.node }
}

/// The rows of one live scope snapshot: at most one page, in discovery order.
public final class SnapshotRows: RowSource {
    public let snapshot: ScopeSnapshot

    public init(_ snapshot: ScopeSnapshot) {
        self.snapshot = snapshot
    }

    public var count: Int { snapshot.rows.count }

    public func row(at index: Int) -> ScopeRow? {
        snapshot.rows.indices.contains(index) ? snapshot.rows[index] : nil
    }

    public func index(ofNode id: Int) -> Int? {
        snapshot.rows.firstIndex { $0.node.id == id }
    }
}

/// The children of one folder of a settled result. `ids` is a slice of the result's shared index, so its own indices
/// do not start at 0; list positions are offsets from its start.
public final class SettledRows: RowSource {
    public let result: ScanResult
    public let ids: ArraySlice<Int>

    public convenience init(result: ScanResult, parent: Int?) {
        self.init(result: result, ids: result.logicalChildIDs(of: parent))
    }

    package init(result: ScanResult, ids: ArraySlice<Int>) {
        self.result = result
        self.ids = ids
    }

    public var count: Int { ids.count }

    public func row(at index: Int) -> ScopeRow? {
        let position = ids.startIndex + index
        return ids.indices.contains(position) ? result.logicalRow(for: ids[position]) : nil
    }

    public func index(ofNode id: Int) -> Int? {
        ids.firstIndex(of: id).map { $0 - ids.startIndex }
    }

    public func node(at index: Int) -> ScanNode? {
        let position = ids.startIndex + index
        return ids.indices.contains(position) ? result.logicalNode(for: ids[position]) : nil
    }
}
