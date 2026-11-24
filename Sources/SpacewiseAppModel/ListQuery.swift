import Foundation
import SpacewiseCore

/// What a list can be sorted by.
public enum ListSortKey: String, Sendable, CaseIterable {
    case name, allocated, logical, items
}

public struct ListSort: Sendable, Equatable {
    public var key: ListSortKey
    public var ascending: Bool

    public init(key: ListSortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    /// The default display order for live and settled lists.
    public static let standard = ListSort(key: .allocated, ascending: false)
}

/// The person's filter and sort for the current folder's rows.
public struct ListQuery: Sendable, Equatable {
    public var filter: String
    public var sort: ListSort

    public init(filter: String = "", sort: ListSort = .standard) {
        self.filter = filter
        self.sort = sort
    }

    /// The filter as matched: surrounding spaces do not count.
    public var filterText: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isFiltering: Bool { !filterText.isEmpty }
    /// True when a settled child index already matches the query.
    public var isIdentity: Bool { !isFiltering && sort == .standard }

    /// Case- and accent-insensitive substring match, as Finder's name search does.
    public func matches(_ name: String) -> Bool {
        Self.matches(name, text: filterText)
    }

    fileprivate static func matches(_ name: String, text: String) -> Bool {
        text.isEmpty || name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// A filtered and sorted view. Rows are resolved from the original source only when requested.
@MainActor public final class QueriedRows: RowSource {
    public let base: RowSource
    public let query: ListQuery
    private let index: ListQueryIndex

    /// For bounded sources such as live pages. Settled wide lists use the concurrent index builder.
    public convenience init(base: RowSource, query: ListQuery, itemCount: (ScanNode) -> Int? = { _ in nil }) {
        let index = ListQueryIndex.build(
            count: base.count, query: query, ranked: base is SettledRows,
            nodeAt: base.node(at:), itemCount: itemCount, checking: {})
        self.init(base: base, query: query, index: index)
    }

    fileprivate init(base: RowSource, query: ListQuery, index: ListQueryIndex) {
        self.base = base
        self.query = query
        self.index = index
    }

    public var count: Int { index.positions.count }

    public func row(at index: Int) -> ScopeRow? {
        self.index.positions.indices.contains(index) ? base.row(at: self.index.positions[index]) : nil
    }

    public func node(at index: Int) -> ScanNode? {
        self.index.positions.indices.contains(index) ? base.node(at: self.index.positions[index]) : nil
    }

    public func index(ofNode id: Int) -> Int? { index.byID[id] }
}

private struct ListQueryIndex: Sendable {
    var positions: [Int] = []
    var byID: [Int: Int] = [:]

    private enum Key {
        case name(String)
        case number(UInt64)
        case count(Int)
        case unknown

        init(node: ScanNode, sort: ListSortKey, itemCount: (ScanNode) -> Int?) {
            let value: UInt64?
            switch sort {
            case .name:
                self = .name(node.name)
                return
            case .allocated, .logical:
                value = node.listSize(logical: sort == .logical)
            case .items:
                self = itemCount(node).map(Self.count) ?? .unknown
                return
            }
            self = value.map(Self.number) ?? .unknown
        }

        /// Nil means a tie. Unknown entries follow measured ones in either direction.
        func precedes(_ other: Self, ascending: Bool) -> Bool? {
            switch (self, other) {
            case (.unknown, .unknown): return nil
            case (.unknown, _): return false
            case (_, .unknown): return true
            case (.name(let left), .name(let right)):
                let comparison = left.localizedStandardCompare(right)
                guard comparison != .orderedSame else { return nil }
                return comparison == (ascending ? .orderedAscending : .orderedDescending)
            case (.number(let left), .number(let right)):
                guard left != right else { return nil }
                return ascending ? left < right : left > right
            case (.count(let left), .count(let right)):
                guard left != right else { return nil }
                return ascending ? left < right : left > right
            default:
                preconditionFailure("List query keys must use the same sort column")
            }
        }
    }

    @concurrent static func build(result: ScanResult, ids: ArraySlice<Int>, query: ListQuery) async throws -> Self {
        try build(
            count: ids.count, query: query, ranked: true,
            nodeAt: { result.logicalNode(for: ids[ids.startIndex + $0]) },
            itemCount: { result.itemCount(of: $0.id) }, checking: Task.checkCancellation)
    }

    static func build(
        count: Int, query: ListQuery, ranked: Bool, nodeAt: (Int) -> ScanNode?,
        itemCount: (ScanNode) -> Int?, checking: () throws -> Void
    ) rethrows -> Self {
        try checking()
        let text = query.filterText
        let sort = query.sort
        let needsSort = sort != .standard || !ranked
        var sorted: [(position: Int, id: Int, key: Key)] = []
        var index = Self()
        if needsSort && text.isEmpty { sorted.reserveCapacity(count) }
        for position in 0..<count {
            if position.isMultiple(of: 1024) { try checking() }
            guard let node = nodeAt(position),
                ListQuery.matches(node.name, text: text)
            else { continue }
            if needsSort {
                sorted.append((position, node.id, Key(node: node, sort: sort.key, itemCount: itemCount)))
            } else {
                index.append(position: position, id: node.id)
            }
        }

        if needsSort {
            var comparisons = 0
            try sorted.sort { left, right in
                comparisons += 1
                if comparisons.isMultiple(of: 1024) { try checking() }
                return left.key.precedes(right.key, ascending: sort.ascending) ?? (left.position < right.position)
            }
            index.positions.reserveCapacity(sorted.count)
            index.byID.reserveCapacity(sorted.count)
            for (offset, row) in sorted.enumerated() {
                if offset.isMultiple(of: 1024) { try checking() }
                index.append(position: row.position, id: row.id)
            }
        }
        try checking()
        return index
    }

    private mutating func append(position: Int, id: Int) {
        byID[id] = positions.count
        positions.append(position)
    }
}

/// Keeps one result for the current base and query. A settled base is unique to its result and scope request.
@MainActor public final class ListQueryCache {
    private var cached: QueriedRows?
    private var pending: (base: SettledRows, query: ListQuery)?
    package private(set) var task: Task<Void, Never>?

    public init() {}

    public func cancel() {
        task?.cancel()
        pending = nil
        cached = nil
    }

    /// Bounded sources and the settled identity fast path are available immediately.
    package func rows(for base: RowSource?, query: ListQuery) -> RowSource? {
        guard let base, !(query.isIdentity && base is SettledRows) else {
            cancel()
            return base
        }
        if let cached, cached.base === base, cached.query == query { return cached }
        let result = (base as? SettledRows)?.result
        let rows = QueriedRows(base: base, query: query) { result?.itemCount(of: $0.id) }
        cached = rows
        return rows
    }

    /// An absent result with a nonempty base means that this query is still running.
    public func requestRows(for base: RowSource?, query: ListQuery, onReady: @escaping @MainActor () -> Void)
        -> RowSource?
    {
        guard let settled = base as? SettledRows, settled.count > ScopeSnapshot.pageSize, !query.isIdentity else {
            if pending != nil { cancel() }
            return rows(for: base, query: query)
        }
        if let cached, cached.base === settled, cached.query == query { return cached }
        if let pending, pending.base === settled, pending.query == query { return nil }

        // Retire the previous job before allocating another wide working set.
        let previous = task
        cancel()
        pending = (settled, query)
        let result = settled.result
        let ids = settled.ids
        task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled,
                let index = try? await ListQueryIndex.build(result: result, ids: ids, query: query),
                !Task.isCancelled, let self, let pending = self.pending,
                pending.base === settled, pending.query == query
            else { return }
            self.task = nil
            self.pending = nil
            self.cached = QueriedRows(base: settled, query: query, index: index)
            onReady()
        }
        return nil
    }
}
