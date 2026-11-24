import Foundation

public enum TreemapBuilder {
    private struct Cursor {
        var tile: Int
        var items: [(id: Int, weight: UInt64)]
        var total: Int
        var next = 0
    }
    private struct Work {
        var nodeID: Int
        var parent: Int
        var kind: TreemapTile.Kind
        var category: FileCategory
        var weight: UInt64
        var partial: Bool
        var row: ScopeRow?
        var children: [Int] = []
        var itemCount = 0
        var cursor: Int?
        var managed = false
        var tint: FileCategory?
    }
    private struct Entry {
        var weight: UInt64
        var sequence: Int
        var cursor: Int
    }
    private struct Heap {
        var items: [Entry] = []
        private static func before(_ a: Entry, _ b: Entry) -> Bool {
            a.weight != b.weight ? a.weight > b.weight : a.sequence < b.sequence
        }
        mutating func push(_ entry: Entry) {
            items.append(entry)
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard Self.before(items[child], items[parent]) else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }
        mutating func popFirst() -> Entry? {
            guard let top = items.first else { return nil }
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var parent = 0
                while true {
                    let left = parent * 2 + 1
                    let right = left + 1
                    var best = parent
                    if left < items.count, Self.before(items[left], items[best]) { best = left }
                    if right < items.count, Self.before(items[right], items[best]) { best = right }
                    if best == parent { break }
                    items.swapAt(best, parent)
                    parent = best
                }
            }
            return top
        }
    }

    /// Largest-first expansion. A global priority queue always materializes the heaviest not-yet-drawn item whose
    /// parent is drawn, so the biggest real files get their own tiles wherever they sit in the tree. Whatever is
    /// left under an expanded folder becomes one aggregate with an exact combined size.
    static func build(
        source: some TreemapSource, scope: Int?, provisional: Bool, limits: TreemapLimits = .standard,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> TreemapModel {
        let clock = ContinuousClock()
        let began = clock.now
        var work = [
            Work(
                nodeID: scope ?? -1, parent: -1, kind: .folder, category: .folderBlock,
                weight: scope.map { source.weight(of: $0) } ?? source.rootWeight,
                partial: provisional, row: nil,
                managed: source.managedZones
                    && (scope.map {
                        $0 == LogicalNamespace.managedGroupID
                            || source.row(for: $0)?.classification == .systemManaged
                    } ?? false))
        ]
        var cursors: [Cursor] = []
        var heap = Heap()
        var sequence = 0
        var stats = TreemapStats()
        var cost = 0
        // One ledger for the whole build: selection, row synthesis and sampling all draw from `maxCost`.
        func budgetLeft() -> Int { max(0, limits.maxCost - cost) }
        var expanded = 0  // folders with at least one drawn child; each may add one aggregate tile after the loop
        func openCursor(tile: Int, id: Int?) {
            if source.selectionCost(of: id, limit: limits.maxPerFolder) > budgetLeft() {
                stats.limited = true
                return
            }
            let found = source.largestChildren(of: id, limit: limits.maxPerFolder)
            if found.cost > budgetLeft() {
                stats.limited = true
                return
            }
            cost += found.cost
            work[tile].itemCount = found.total
            if found.total > found.items.count && found.items.count >= limits.maxPerFolder { stats.limited = true }
            guard let head = found.items.first else { return }
            cursors.append(Cursor(tile: tile, items: found.items, total: found.total))
            work[tile].cursor = cursors.count - 1
            heap.push(Entry(weight: head.weight, sequence: sequence, cursor: cursors.count - 1))
            sequence += 1
        }
        openCursor(tile: 0, id: scope)
        let scopeWeight = max(work[0].weight, cursors.first.map { $0.items.reduce(0) { $0 + $1.weight } } ?? 0)
        // Items under ~0.25 ppm of the scope cannot be seen even on a very large display.
        let minimum = max(1, scopeWeight / 4_000_000)
        var steps = 0
        while work.count + expanded + 2 <= limits.maxTiles, let top = heap.popFirst() {
            steps += 1
            if steps & 0xFF == 0, isCancelled() {
                stats.limited = true
                break
            }
            if top.weight < minimum { break }
            var cursor = cursors[top.cursor]
            let item = cursor.items[cursor.next]
            // Row synthesis is charged before it happens; an unaffordable row ends expansion (its weight stays in the
            // aggregate).
            let rowCost = max(1, source.rowCost(of: item.id))
            if rowCost > budgetLeft() {
                stats.limited = true
                break
            }
            cost += rowCost
            cursor.next += 1
            if cursor.next < cursor.items.count {
                heap.push(Entry(weight: cursor.items[cursor.next].weight, sequence: sequence, cursor: top.cursor))
                sequence += 1
            }
            cursors[top.cursor] = cursor
            guard let row = source.row(for: item.id) else { continue }
            let node = row.node
            let kind: TreemapTile.Kind =
                node.kind == .directory
                ? .folderBlock
                : (node.kind == .package ? .package : .file)
            let category: FileCategory =
                kind == .folderBlock
                ? .folderBlock
                : FileCategory.category(name: node.name, kind: node.kind)
            let partial = node.allocationUnknown || (row.coverage != .measured)
            let index = work.count
            work.append(
                Work(
                    nodeID: node.id, parent: cursor.tile, kind: kind, category: category, weight: item.weight,
                    partial: partial, row: row,
                    managed: work[cursor.tile].managed
                        || (source.managedZones && row.classification == .systemManaged)))
            if work[cursor.tile].children.isEmpty { expanded += 1 }
            work[cursor.tile].children.append(index)
            if work[cursor.tile].kind == .folderBlock { work[cursor.tile].kind = .folder }
            if kind == .folderBlock { openCursor(tile: index, id: node.id) }
        }
        if !heap.items.isEmpty && work.count + expanded + 2 > limits.maxTiles { stats.limited = true }
        if work[0].children.isEmpty && work[0].weight > 0 {
            // Selection or expansion was refused (budget, or no sized children): retain the exact scope weight as one
            // collapsed block rather than falling back to a physical root or losing area.
            work.append(
                Work(
                    nodeID: scope ?? -1, parent: 0, kind: .folderBlock,
                    category: .folderBlock, weight: work[0].weight,
                    partial: provisional, row: nil, managed: work[0].managed))
            work[0].children = [1]
            work[0].itemCount = 0
            work[0].cursor = nil
        }

        // Aggregates: everything under an expanded folder that did not get its own tile, summed exactly.
        let drawnCount = work.count
        for index in 0..<drawnCount where !work[index].children.isEmpty {
            let drawn = work[index].children.count
            let childSum = work[index].children.reduce(UInt64(0)) { $0 + work[$1].weight }
            let remaining = work[index].itemCount - drawn
            let remainder = work[index].weight > childSum ? work[index].weight - childSum : 0
            guard remaining > 0 else { continue }
            if remainder > 0 {
                var group = Work(
                    nodeID: -1, parent: index, kind: .aggregate, category: .grouped, weight: remainder,
                    partial: work[index].partial, row: nil, itemCount: remaining)
                group.managed = work[index].managed
                if let slot = work[index].cursor, budgetLeft() > 0 {
                    let estimate = estimateTint(of: cursors[slot], source: source, allowance: min(512, budgetLeft()))
                    cost += estimate.consumed
                    group.tint = estimate.tint
                }
                work.append(group)
                work[index].children.append(work.count - 1)
                stats.itemsGrouped += remaining
                stats.aggregates += 1
            } else {
                stats.itemsWithoutSize += remaining
            }
        }
        // Folder blocks: colour by the main file type among their largest items (settled maps only; an estimate).
        if !provisional {
            let blocks = work.indices
                .filter { work[$0].kind == .folderBlock && work[$0].nodeID >= 0 }
                .sorted { work[$0].weight > work[$1].weight }
            for index in blocks.prefix(1500) {
                if steps & 0xFF == 0, isCancelled() { break }
                steps += 1
                // Local ceiling of 40 reads per block, shared by all of its members, within what the ledger has left.
                let allowance = min(40, budgetLeft())
                guard allowance > 0 else { break }
                let sample = source.sampleCategories(under: work[index].nodeID, visits: allowance)
                cost += sample.consumed
                if let categories = sample.categories { work[index].tint = dominant(categories) }
            }
        }
        stats.cost = cost
        // A parent can never be lighter than its children (provisional skew); parents precede children.
        for index in work.indices.reversed() where !work[index].children.isEmpty {
            let sum = work[index].children.reduce(UInt64(0)) { $0 + work[$1].weight }
            if sum > work[index].weight { work[index].weight = sum }
        }

        // Flatten breadth-first so each tile's children are contiguous. Children are heaviest first, aggregates last
        // on ties.
        var order = [0]
        order.reserveCapacity(work.count)
        var firstChild = [Int](repeating: 0, count: work.count)
        var depth = [Int](repeating: 0, count: work.count)
        var head = 0
        while head < order.count {
            let id = order[head]
            head += 1
            let kids = work[id].children.sorted { a, b in
                if work[a].weight != work[b].weight { return work[a].weight > work[b].weight }
                if (work[a].kind == .aggregate) != (work[b].kind == .aggregate) { return work[b].kind == .aggregate }
                return a < b
            }
            firstChild[id] = order.count
            for kid in kids {
                depth[kid] = depth[id] + 1
                order.append(kid)
            }
            work[id].children = kids
        }
        var position = [Int](repeating: -1, count: work.count)
        for (slot, old) in order.enumerated() { position[old] = slot }
        var tiles: [TreemapTile] = []
        var rows: [ScopeRow?] = []
        tiles.reserveCapacity(order.count)
        rows.reserveCapacity(order.count)
        for old in order {
            let item = work[old]
            tiles.append(
                TreemapTile(
                    nodeID: item.nodeID, parent: item.parent < 0 ? -1 : position[item.parent],
                    kind: item.kind, category: item.category, weight: item.weight, depth: depth[old],
                    firstChild: item.children.isEmpty ? 0 : firstChild[old],
                    childCount: item.children.count, partial: item.partial, itemCount: item.itemCount,
                    managed: item.managed, tint: item.tint))
            rows.append(item.row)
        }
        for tile in tiles.dropFirst() {
            if tile.kind != .aggregate { stats.itemsDrawn += 1 }
            if tile.kind == .folder { stats.folders += 1 }
            if tile.kind == .folderBlock { stats.collapsedFolders += 1 }
            if tile.partial && tile.kind != .aggregate { stats.partialTiles += 1 }
        }
        stats.buildSeconds = began.duration(to: clock.now).totalSeconds
        return TreemapModel(scope: scope, provisional: provisional, tiles: tiles, rows: rows, stats: stats)
    }

    /// The main file type when it holds a clear share of what was sampled; nil when mixed or empty.
    private static func dominant(_ sample: [FileCategory: UInt64]) -> FileCategory? {
        let total = sample.values.reduce(0, +)
        guard total > 0,
            let best = sample.max(by: {
                $0.value != $1.value ? $0.value < $1.value : $0.key.rawValue > $1.key.rawValue
            })
        else { return nil }
        return Double(best.value) >= Double(total) * 0.35 ? best.key : nil
    }
    private static func estimateTint(
        of cursor: Cursor, source: some TreemapSource,
        allowance: Int
    ) -> (tint: FileCategory?, consumed: Int) {
        var sample: [FileCategory: UInt64] = [:]
        var consumed = 0
        for item in cursor.items.dropFirst(cursor.next).prefix(allowance) {
            consumed += 1
            guard let info = source.info(of: item.id), info.kind != .directory else { continue }
            sample[FileCategory.category(name: info.name, kind: info.kind), default: 0] += item.weight
        }
        return (dominant(sample), consumed)
    }

    /// Settled results: built off the main actor. The result is an immutable value shared copy-on-write.
    @concurrent public static func build(
        result: ScanResult, parent: Int?,
        limits: TreemapLimits = .standard
    ) async -> TreemapModel {
        build(source: result.logicalSource(), scope: parent, provisional: false, limits: limits)
    }
}

extension ScanResult {
    /// Synchronous form for tests and small scopes; the app uses the async builder.
    public func treemap(parent: Int?, limits: TreemapLimits = .standard) -> TreemapModel {
        TreemapBuilder.build(
            source: logicalSource(), scope: parent, provisional: false, limits: limits,
            isCancelled: { false })
    }
}
