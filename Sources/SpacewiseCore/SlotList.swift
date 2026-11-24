import Foundation

/// Ordered logical children of one folder, in discovery order. One slot per distinct name; a slot normally shows one
/// entry, and shows several only for real entries that cannot merge (for example files sharing a name). Replacing the
/// entries of one slot never shifts another slot, and a page read costs O(log slots + page), so a growing folder is
/// neither re-sorted nor flattened to paginate. Values are Sendable; the scanner worker is the only mutator.
struct SlotList: Sendable {
    private(set) var heads: [Int] = []
    /// Entries after the first of a slot (rare). Sparse.
    private var extras: [Int: [Int]] = [:]
    /// Fenwick tree over per-slot extra counts, 1-based. Empty until the first extra exists.
    private var tree: [Int] = []
    /// Visible entries.
    private(set) var count = 0
    /// Base reads needed to weigh every visible entry: the conservative cost of selecting from this list.
    var cost = 0

    var slotCount: Int { heads.count }

    @discardableResult
    mutating func append(_ id: Int) -> Int {
        heads.append(id)
        count += 1
        if !tree.isEmpty {
            let index = heads.count
            tree.append(prefix(index - 1) - prefix(index - (index & -index)))
        }
        return heads.count - 1
    }

    /// Replace the visible entries of one slot. `ids` is never empty.
    mutating func set(slot: Int, _ ids: [Int]) {
        let before = extras[slot]?.count ?? 0
        let after = ids.count - 1
        heads[slot] = ids[0]
        extras[slot] = after > 0 ? Array(ids.dropFirst()) : nil
        guard after != before else { return }
        count += after - before
        if tree.isEmpty { rebuildTree() } else { add(slot: slot, delta: after - before) }
    }

    func entries(of slot: Int) -> [Int] { [heads[slot]] + (extras[slot] ?? []) }

    var all: [Int] { all(checking: {}) }

    func all(checking: () throws -> Void) rethrows -> [Int] {
        guard !extras.isEmpty else { return heads }
        var out: [Int] = []
        out.reserveCapacity(count)
        for slot in heads.indices {
            if slot.isMultiple(of: 1024) { try checking() }
            out.append(heads[slot])
            if let more = extras[slot] {
                for (index, id) in more.enumerated() {
                    if index.isMultiple(of: 1024) { try checking() }
                    out.append(id)
                }
            }
        }
        return out
    }

    /// Discovery-order page; offsets and limits are clamped.
    func page(offset: Int, limit: Int) -> [Int] {
        let start = min(max(0, offset), count)
        let wanted = min(max(0, limit), count - start)
        guard wanted > 0 else { return [] }
        guard !extras.isEmpty else { return Array(heads[start..<(start + wanted)]) }
        // Largest slot whose first visible position is at or before `start`.
        var low = 0
        var high = heads.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if middle + prefix(middle) <= start { low = middle } else { high = middle - 1 }
        }
        var skip = start - (low + prefix(low))
        var out: [Int] = []
        out.reserveCapacity(wanted)
        var slot = low
        while out.count < wanted, slot < heads.count {
            let entries = self.entries(of: slot)
            for id in entries.dropFirst(skip) where out.count < wanted { out.append(id) }
            skip = 0
            slot += 1
        }
        return out
    }

    // Extras in slots [0, slots).
    private func prefix(_ slots: Int) -> Int {
        var index = slots
        var sum = 0
        while index > 0 {
            sum += tree[index]
            index -= index & -index
        }
        return sum
    }
    private mutating func add(slot: Int, delta: Int) {
        var index = slot + 1
        while index < tree.count {
            tree[index] += delta
            index += index & -index
        }
    }
    private mutating func rebuildTree() {
        tree = [Int](repeating: 0, count: heads.count + 1)
        for (slot, more) in extras { tree[slot + 1] = more.count }
        for index in 1..<tree.count {
            let parent = index + (index & -index)
            if parent < tree.count { tree[parent] += tree[index] }
        }
    }
}
