import Foundation

/// Read access the builder needs. Settled and provisional storage implement it; the algorithm is shared.
///
/// Budget contract: the builder owns one work ledger (`TreemapLimits.maxCost`). A source never does unaccounted work:
/// `selectionCost` bounds, before selection starts, every read `largestChildren` will make (including merged member
/// weights); `rowCost` is charged before each `row(for:)`; sampling receives its remaining allowance and reports
/// what it consumed. Only the scope's own weight (O(members) of one folder, never a traversal) is read outside it.
protocol TreemapSource {
    /// Children of `parent` (nil = scan roots) that have allocated weight, heaviest first (ties by name, then ID),
    /// at most `limit`. `total` counts every child including unsized ones. `cost` is the number of reads performed.
    func largestChildren(of parent: Int?, limit: Int) -> (items: [(id: Int, weight: UInt64)], total: Int, cost: Int)
    func selectionCost(of parent: Int?) -> Int
    /// Upper bound of the reads `largestChildren(of:limit:)` performs. Defaults to `selectionCost(of:)`.
    func selectionCost(of parent: Int?, limit: Int) -> Int
    var rootWeight: UInt64 { get }
    func weight(of id: Int) -> UInt64
    func row(for id: Int) -> ScopeRow?
    /// Reads `row(for:)` performs (a merged folder reads every member).
    func rowCost(of id: Int) -> Int
    /// True when rows carry logical (unified drive) classification, so system-managed tiles get their own treatment.
    var managedZones: Bool { get }
    /// Name and kind only; used to estimate the main file type of blocks and groups without building rows.
    func info(of id: Int) -> (name: String, kind: NodeKind)?
    /// File-type weights among the heaviest descendants of a folder. Reads at most `visits` entries across all of the
    /// folder's physical members and reports how many it read. nil categories when unavailable.
    func sampleCategories(under id: Int, visits: Int) -> (categories: [FileCategory: UInt64]?, consumed: Int)
}
extension TreemapSource {
    func selectionCost(of parent: Int?) -> Int { 0 }
    func selectionCost(of parent: Int?, limit: Int) -> Int { selectionCost(of: parent) }
    var rootWeight: UInt64 { 0 }
    func rowCost(of id: Int) -> Int { 1 }
    var managedZones: Bool { false }
    func info(of id: Int) -> (name: String, kind: NodeKind)? { nil }
    func sampleCategories(under id: Int, visits: Int) -> (categories: [FileCategory: UInt64]?, consumed: Int) {
        (nil, 0)
    }
}

/// Keeps the `limit` heaviest entries of a stream in a min-heap (root = the entry that would be dropped first).
/// Ordering is weight, then name, then id, the order tiles are listed in. Unsized entries are ignored.
struct HeaviestSelection {
    private let limit: Int
    private let name: (Int) -> String
    private var heap: [(id: Int, weight: UInt64)] = []
    init(limit: Int, name: @escaping (Int) -> String) {
        self.limit = limit
        self.name = name
    }
    /// True when `a` would be dropped before `b`.
    private func worse(_ a: (id: Int, weight: UInt64), _ b: (id: Int, weight: UInt64)) -> Bool {
        if a.weight != b.weight { return a.weight < b.weight }
        let left = name(a.id)
        let right = name(b.id)
        return left != right ? left > right : a.id > b.id
    }
    mutating func offer(id: Int, weight: UInt64) {
        guard weight > 0, limit > 0 else { return }
        let entry = (id: id, weight: weight)
        if heap.count < limit {
            heap.append(entry)
            var child = heap.count - 1
            while child > 0 {
                let up = (child - 1) / 2
                if worse(heap[child], heap[up]) {
                    heap.swapAt(child, up)
                    child = up
                } else {
                    break
                }
            }
        } else if worse(heap[0], entry) {
            heap[0] = entry
            var parent = 0
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var smallest = parent
                if left < heap.count, worse(heap[left], heap[smallest]) { smallest = left }
                if right < heap.count, worse(heap[right], heap[smallest]) { smallest = right }
                if smallest == parent { break }
                heap.swapAt(smallest, parent)
                parent = smallest
            }
        }
    }
    func ordered() -> [(id: Int, weight: UInt64)] { heap.sorted { worse($1, $0) } }
}

/// Reads the settled, size-ranked child index. Prefix reads; no sorting and no node copies.
struct SettledTreemapSource: TreemapSource {
    let result: ScanResult
    var rootWeight: UInt64 { result.childIDs(of: nil).reduce(0) { $0 + weight(of: $1) } }
    func selectionCost(of parent: Int?, limit: Int) -> Int {
        let count = result.childIDs(of: parent).count
        return result.childrenAreRanked(of: parent) ? min(count, limit) : count
    }
    func largestChildren(of parent: Int?, limit: Int) -> (items: [(id: Int, weight: UInt64)], total: Int, cost: Int) {
        let ids = result.childIDs(of: parent)
        if !result.childrenAreRanked(of: parent) {
            var selection = HeaviestSelection(limit: limit) { result.nodes[$0].name }
            for id in ids { selection.offer(id: id, weight: weight(of: id)) }
            return (selection.ordered(), ids.count, ids.count)
        }
        var items: [(id: Int, weight: UInt64)] = []
        var reads = 0
        for id in ids.prefix(limit) {
            reads += 1
            let weight = result.nodes[id].allocatedBytes
            if weight == 0 { break }  // index is sorted by allocated size, so the rest are unsized
            items.append((id, weight))
        }
        return (items, ids.count, reads)
    }
    func weight(of id: Int) -> UInt64 { result.node(for: id)?.allocatedBytes ?? 0 }
    func row(for id: Int) -> ScopeRow? { result.scopeRow(for: id) }
    func info(of id: Int) -> (name: String, kind: NodeKind)? { result.node(for: id).map { ($0.name, $0.kind) } }
    /// Heaviest-first walk of at most `visits` entries (every node read counts, including the unsized one that ends a
    /// folder's prefix); reads names and sizes only.
    func sampleCategories(under id: Int, visits: Int) -> (categories: [FileCategory: UInt64]?, consumed: Int) {
        var out: [FileCategory: UInt64] = [:]
        var budget = visits
        var stack = [id]
        walk: while budget > 0, let folder = stack.popLast() {
            guard result.childrenAreRanked(of: folder) else { continue }
            var folders: [Int] = []
            for child in result.childIDs(of: folder).prefix(8) {
                guard budget > 0 else { break walk }
                budget -= 1
                let node = result.nodes[child]
                if node.allocatedBytes == 0 { break }
                if node.kind == .directory {
                    folders.append(child)
                } else {
                    out[FileCategory.category(name: node.name, kind: node.kind), default: 0] += node.allocatedBytes
                }
            }
            stack.append(contentsOf: folders.reversed())
        }
        return (out.isEmpty ? nil : out, visits - budget)
    }
}
