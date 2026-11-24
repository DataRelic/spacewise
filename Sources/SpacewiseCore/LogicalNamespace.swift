import Foundation

// Unified startup-drive presentation. A whole-drive scan traverses the sealed System volume (mounted at /), the
// writable Data volume (firm-linked into /) and a few auxiliary volumes as separate roots. People see one drive
// rooted at /. This overlay maps physical nodes onto one logical tree without touching them:
//   * identity: a logical node is its *primary physical node*; ids never change, merged or not;
//   * a folder that is a real directory on both volumes (/System, /System/Library, /usr, /private ...) becomes one
//     logical folder whose members are the physical directories; its totals are the sum of the members;
//   * a firm-link stub (a boundary-excluded, zero-byte directory on one side) is absorbed by the real folder on the
//     other side and never shown as a second row;
//   * entries the path policy classifies as system-managed, plus the auxiliary volume roots, are gathered into one
//     inspectable group (`managedGroupID`). The group holds the real nodes, not copies, so nothing is counted twice.
// Pure and Sendable. It reads the node array and a physical child lookup, never the filesystem. During a scan the
// scanner worker grows one `NamespaceBuilder` incrementally (see NamespaceBuilder.swift); `build` runs the same
// reconciliation once over a settled node array.

public struct LogicalNamespace: Sendable {
    /// Not a physical node id (physical ids are dense indices, always below `nodes.count`). Non-negative so it flows
    /// through every "is this a real node" check that tests `>= 0`; every physical lookup treats it as absent.
    public static let managedGroupID = Int.max
    public static let managedGroupName = "Managed by macOS"

    public static let identity = LogicalNamespace()

    /// True when the drive is presented as one root (a whole-drive scan with a resolvable System/Data pair).
    public internal(set) var unified = false
    public internal(set) var systemRoot: Int?
    public internal(set) var dataRoot: Int?
    /// Primary node → physical members (at least two real directories; the primary is one of them).
    public internal(set) var members: [Int: [Int]] = [:]
    /// A physical node that is not shown itself → the primary that stands for it (merged duplicate or firm-link
    /// stub).
    public internal(set) var hidden: [Int: Int] = [:]
    /// Logical children of each merged folder, in discovery order.
    var merged: [Int: SlotList] = [:]
    /// Logical entries directly under the unified root, outside the managed group.
    var topSlots = SlotList()
    /// Logical entries inside the managed group: system-managed top-level entries and auxiliary volume roots.
    var managedSlots = SlotList()
    var managedSet = Set<Int>()
    /// Authoritative cached totals of the managed group. Maintained by the builder and the scanner's signed attribution
    /// while scanning; recomputed exactly once from finalized nodes when the scan settles.
    var managedAggregate = MeasuredCategory()
    var managedPhysicalRoots = Set<Int>()

    public init() {}

    /// Compatibility materializations for explicit, unbounded callers (tests, settled lists). Snapshot and map paths
    /// use `page` and `listCost` instead.
    public var topLevel: [Int] { topSlots.all }
    public var managed: [Int] { managedSlots.all }

    public func logicalID(_ physical: Int) -> Int { hidden[physical] ?? physical }
    public func isMerged(_ id: Int) -> Bool { members[id] != nil }
    public func physicalMembers(of id: Int) -> [Int] { members[id] ?? [id] }

    /// The list a logical scope shows when it is not simply one physical folder; nil means "use the physical children".
    public func list(for scope: Int?) -> [Int]? { list(for: scope, checking: {}) }

    fileprivate func list(for scope: Int?, checking: () throws -> Void) rethrows -> [Int]? {
        guard unified else { return nil }
        guard let scope else {
            var ids = try topSlots.all(checking: checking)
            if managedSlots.count > 0 { ids.append(Self.managedGroupID) }
            return ids
        }
        if scope == Self.managedGroupID { return try managedSlots.all(checking: checking) }
        return try merged[scope]?.all(checking: checking)
    }

    /// Discovery-order page without copying the full list.
    func page(for scope: Int?, offset: Int, limit: Int) -> (ids: [Int], total: Int)? {
        guard unified else { return nil }
        guard let scope else {
            let hasGroup = managedSlots.count > 0
            let total = topSlots.count + (hasGroup ? 1 : 0)
            let start = min(max(0, offset), total)
            let end = start + min(max(0, limit), total - start)
            var ids = topSlots.page(offset: start, limit: min(end, topSlots.count) - start)
            if hasGroup, start <= topSlots.count, end > topSlots.count { ids.append(Self.managedGroupID) }
            return (ids, total)
        }
        if scope == Self.managedGroupID { return (managedSlots.page(offset: offset, limit: limit), managedSlots.count) }
        guard let list = merged[scope] else { return nil }
        return (list.page(offset: offset, limit: limit), list.count)
    }

    /// Number of logical entries in a logical scope's list; nil when the scope is plain physical.
    package func listCount(for scope: Int?) -> Int? {
        guard unified else { return nil }
        guard let scope else { return topSlots.count + (managedSlots.count == 0 ? 0 : 1) }
        if scope == Self.managedGroupID { return managedSlots.count }
        return merged[scope]?.count
    }

    /// Conservative number of base reads needed to weigh every entry of the scope's list (merged entries read each
    /// member; the managed group reads its cached aggregate). nil when the scope is plain physical.
    func listCost(for scope: Int?) -> Int? {
        guard unified else { return nil }
        guard let scope else { return topSlots.cost + (managedSlots.count == 0 ? 0 : 1) }
        if scope == Self.managedGroupID { return managedSlots.cost }
        return merged[scope]?.cost
    }

    /// The logical parent. nil is the unified root (or, for a non-unified result, a scan root).
    public func parent(of id: Int, nodes: [ScanNode]) -> Int? {
        if id == Self.managedGroupID { return nil }
        guard nodes.indices.contains(id) else { return nil }
        guard unified else { return nodes[id].parent }
        guard let physical = nodes[id].parent else { return managedSet.contains(id) ? Self.managedGroupID : nil }
        if physical == systemRoot || physical == dataRoot { return managedSet.contains(id) ? Self.managedGroupID : nil }
        return logicalID(physical)
    }

    /// Ancestors from the top down to `id` itself, as logical ids.
    public func chain(to id: Int, nodes: [ScanNode]) -> [Int] {
        var out: [Int] = []
        var cursor: Int? = id
        var hops = 0
        while let current = cursor, hops < 100_000 {
            out.append(current)
            cursor = parent(of: current, nodes: nodes)
            hops += 1
        }
        return out.reversed()
    }

    // MARK: Construction

    /// One-shot construction over a settled node array. `children` returns every physical child of a node. `rootPaths`
    /// maps each scan-root node to its path. Returns identity when cancelled.
    static func build<Children: Sequence>(
        nodes: [ScanNode], rootPaths: [Int: String], wholeDrive: Bool,
        isCancelled: @escaping () -> Bool = { Task.isCancelled },
        children: @escaping (Int) -> Children
    ) -> LogicalNamespace
    where Children.Element == Int {
        guard wholeDrive else { return LogicalNamespace() }
        var builder = NamespaceBuilder()
        let finished = builder.buildSettled(
            nodes: nodes, rootPaths: rootPaths, isCancelled: isCancelled,
            children: { Array(children($0)) })
        return finished ? builder.view : .identity
    }

    /// A zero-byte directory the scanner declined to cross: the System-volume side of a firm link.
    static func isStub(_ node: ScanNode) -> Bool {
        (node.issue == .volumeBoundary || node.issue == .policyExcluded) && node.allocatedBytes == 0
    }

    // MARK: Logical values

    /// Totals and flags for a logical node from per-physical-node reads (settled values, or provisional while
    /// scanning).
    public func node(for id: Int, nodes: [ScanNode], read: (Int) -> ScanNode?) -> ScanNode? {
        if id == Self.managedGroupID {
            var node = ScanNode(id: id, parent: nil, name: Self.managedGroupName, kind: .directory, device: 0, inode: 0)
            node.logicalBytes = managedAggregate.logicalBytes
            node.allocatedBytes = managedAggregate.allocatedBytes
            node.allocationUnknown = managedAggregate.allocationUnknown
            return node
        }
        guard var node = read(id) else { return nil }
        if node.parent == nil { node.name = Self.displayName(node) }
        guard let physical = members[id] else { return node }
        node.logicalBytes = 0
        node.allocatedBytes = 0
        node.allocationUnknown = false
        node.issue = nil
        for member in physical {
            // A member that cannot be read contributes nothing, so the merged totals are only a lower bound.
            guard let part = read(member) else {
                node.allocationUnknown = true
                continue
            }
            node.logicalBytes += part.logicalBytes
            node.allocatedBytes += part.allocatedBytes
            node.allocationUnknown = node.allocationUnknown || part.allocationUnknown || part.issue != nil
        }
        return node
    }

    /// The logical row: the primary's row with member totals, or the synthesized managed group.
    func row(for id: Int, nodes: [ScanNode], base: (Int) -> ScopeRow?) -> ScopeRow? {
        if id == Self.managedGroupID {
            guard let node = node(for: id, nodes: nodes, read: { _ in nil }) else { return nil }
            return ScopeRow(
                node: node, classification: .systemManaged,
                coverage: node.allocationUnknown ? .partial : .measured,
                enumeration: nil, eligibility: .inspectionOnly)
        }
        guard let physical = members[id] else { return base(id).map(Self.presented) }
        // One read per member; the primary is one of them.
        let parts = physical.compactMap(base)
        guard let primary = parts.first(where: { $0.node.id == id }),
            let merged = node(
                for: id, nodes: nodes,
                read: { identifier in
                    parts.first { $0.node.id == identifier }?.node
                })
        else { return nil }
        // Full coverage needs a row for every member, not just for the ones that have one.
        let everyMemberMeasured = parts.count == physical.count && parts.allSatisfy { $0.coverage == .measured }
        let coverage: NodeCoverageStatus = everyMemberMeasured ? .measured : .partial
        return ScopeRow(
            node: merged, classification: primary.classification, coverage: coverage,
            enumeration: primary.enumeration, eligibility: .inspectionOnly)
    }

    /// Logical scope summary (breadcrumbs and totals) from logical rows.
    func summary(
        parent: Int?, nodes: [ScanNode], base: (Int) -> ScopeRow?, scanning: Bool,
        issue: (Int) -> CoverageIssue?, enumeration: (Int) -> DirectoryEnumeration?
    ) -> ScopeSummary {
        guard let parent else {
            var logical: UInt64 = 0
            var allocated: UInt64 = 0
            var unknown = scanning
            for id in list(for: nil) ?? [] {
                guard let row = row(for: id, nodes: nodes, base: base) else { continue }
                logical += row.node.logicalBytes
                allocated += row.node.allocatedBytes
                unknown = unknown || row.node.allocationUnknown
            }
            return ScopeSummary(
                crumbs: [], logicalBytes: logical, allocatedBytes: allocated, allocationUnknown: unknown,
                issue: nil, enumeration: nil)
        }
        let crumbs = chain(to: parent, nodes: nodes).map { id in
            ScopeCrumb(id: id, name: id == Self.managedGroupID ? Self.managedGroupName : Self.displayName(nodes[id]))
        }
        guard let value = row(for: parent, nodes: nodes, base: base)?.node else {
            return ScopeSummary(
                crumbs: crumbs, logicalBytes: 0, allocatedBytes: 0, allocationUnknown: true,
                issue: nil, enumeration: nil)
        }
        let pending = enumeration(parent).map { $0 != .enumerated } ?? false
        return ScopeSummary(
            crumbs: crumbs, logicalBytes: value.logicalBytes, allocatedBytes: value.allocatedBytes,
            allocationUnknown: value.allocationUnknown || pending || scanning,
            issue: parent == Self.managedGroupID ? nil : issue(parent),
            enumeration: parent == Self.managedGroupID ? nil : enumeration(parent))
    }

    /// Auxiliary volume roots carry their mount path as the node name; a person reads "VM volume", not a path.
    /// The real path stays in the inspector and in `physicalPaths`.
    public static func displayName(_ node: ScanNode) -> String {
        guard node.parent == nil, node.name.hasPrefix("/"), node.name != "/" else { return node.name }
        return (node.name.split(separator: "/").last.map(String.init) ?? node.name) + " volume"
    }
    private static func presented(_ row: ScopeRow) -> ScopeRow {
        guard row.node.parent == nil, displayName(row.node) != row.node.name else { return row }
        var node = row.node
        node.name = displayName(node)
        return ScopeRow(
            node: node, classification: row.classification, coverage: row.coverage,
            enumeration: row.enumeration, eligibility: row.eligibility)
    }
}

extension ScanResult {
    /// Measured children first, in descending allocated size. A ranked physical folder shares its result slice.
    public func logicalChildIDs(of scope: Int?) -> ArraySlice<Int> {
        logicalChildIDs(of: scope, checking: {})
    }

    package func logicalChildCount(of scope: Int?) -> Int {
        namespace.listCount(for: scope) ?? childIDs(of: scope).count
    }

    package func logicalChildrenAreRanked(of scope: Int?) -> Bool {
        namespace.listCount(for: scope) == nil && childrenAreRanked(of: scope)
    }

    /// Prepare only the requested scope if its logical or physical size index needs ordering.
    @concurrent package func orderedChildIDs(of scope: Int?) async throws -> ArraySlice<Int> {
        try logicalChildIDs(of: scope, checking: Task.checkCancellation)
    }

    private func logicalChildIDs(of scope: Int?, checking: () throws -> Void) rethrows -> ArraySlice<Int> {
        try checking()
        var comparisons = 0
        if let ids = try namespace.list(for: scope, checking: checking) {
            // Compute merged weights once per entry. Each sortable key holds only the fields used by the index.
            var keys: [SizeIndexKey] = []
            keys.reserveCapacity(ids.count)
            for (offset, id) in ids.enumerated() {
                if offset.isMultiple(of: 1024) { try checking() }
                if let node = logicalNode(for: id) { keys.append(node.sizeIndexKey) }
            }
            try keys.sort { left, right in
                comparisons += 1
                if comparisons.isMultiple(of: 1024) { try checking() }
                return left.precedes(right)
            }
            var ordered: [Int] = []
            ordered.reserveCapacity(keys.count)
            for (offset, key) in keys.enumerated() {
                if offset.isMultiple(of: 1024) { try checking() }
                ordered.append(key.id)
            }
            try checking()
            return ordered[...]
        }
        let ids = childIDs(of: scope)
        guard !childrenAreRanked(of: scope) else { return ids }
        let ordered = try ids.sorted { left, right in
            comparisons += 1
            if comparisons.isMultiple(of: 1024) { try checking() }
            return nodes[left].precedesInSizeIndex(nodes[right])
        }
        try checking()
        return ordered[...]
    }
    public func logicalNode(for id: Int) -> ScanNode? {
        guard namespace.unified else { return node(for: id) }
        return namespace.node(for: id, nodes: nodes, read: { [self] in node(for: $0) })
    }
    public func logicalRow(for id: Int) -> ScopeRow? {
        guard namespace.unified else { return scopeRow(for: id) }
        return namespace.row(for: id, nodes: nodes) { [self] in scopeRow(for: $0) }
    }
    public func logicalParent(of id: Int) -> Int? { namespace.parent(of: id, nodes: nodes) }
    public func logicalSummary(parent: Int?) -> ScopeSummary {
        guard namespace.unified, parent != nil else { return scopeSummary(parent: parent) }
        return namespace.summary(
            parent: parent, nodes: nodes, base: { [self] in scopeRow(for: $0) }, scanning: false,
            issue: { [self] in nodes.indices.contains($0) ? nodes[$0].issue : nil },
            enumeration: { [self] in coverage.enumeration[$0] })
    }
    /// The scope that opens when a live request settles. Without the unified overlay, show the measured roots:
    /// both a synthetic group and the physical ID behind a merged folder can lose their live meaning.
    public func settledScope(for liveParent: Int?) -> Int? {
        guard let liveParent else { return nil }
        if coverage.wholeDrive, progress.cancelled, !namespace.unified { return nil }
        if liveParent == LogicalNamespace.managedGroupID {
            return namespace.unified && !namespace.managedSet.isEmpty ? liveParent : nil
        }
        let parent = namespace.logicalID(liveParent)
        guard let node = node(for: parent), node.kind == .directory || node.kind == .package else { return nil }
        return parent
    }
    /// Map for a logical scope. Settled; built from the shared index, never the whole tree.
    public func logicalTreemap(parent: Int?, limits: TreemapLimits = .standard) -> TreemapModel {
        TreemapBuilder.build(
            source: logicalSource(), scope: parent, provisional: false, limits: limits,
            isCancelled: { false })
    }
    func logicalSource() -> some TreemapSource {
        LogicalTreemapSource(base: SettledTreemapSource(result: self), namespace: namespace, nodes: nodes)
    }
    /// The path a person recognizes: the Data volume's firm-linked paths are shown rooted at /. nil for the managed
    /// group.
    public func logicalPathString(for id: Int) -> String? {
        id == LogicalNamespace.managedGroupID ? nil : logicalPath(for: id)
    }
    /// Every physical location behind a logical node (merged folders have one per volume).
    public func physicalPaths(for id: Int) -> [String] {
        if id == LogicalNamespace.managedGroupID { return namespace.managed.compactMap { url(for: $0)?.path } }
        return namespace.physicalMembers(of: id).compactMap { url(for: $0)?.path }
    }
}

/// Logical reads over a physical source: merged folders sum their members, the unified root and the managed group list
/// logical entries, everything else delegates so a million-child folder keeps its prefix-read fast path. Every read
/// beyond the scope's own weight is reported to the builder's ledger (see `TreemapSource`): selection cost counts the
/// member weights of merged entries, row cost counts member rows, and sampling is shared across a folder's members.
struct LogicalTreemapSource<Base: TreemapSource>: TreemapSource {
    let base: Base
    let namespace: LogicalNamespace
    let nodes: [ScanNode]
    var managedZones: Bool { namespace.unified }

    var rootWeight: UInt64 { base.rootWeight }
    func selectionCost(of parent: Int?) -> Int { selectionCost(of: parent, limit: Int.max) }
    func selectionCost(of parent: Int?, limit: Int) -> Int {
        namespace.listCost(for: parent) ?? base.selectionCost(of: parent, limit: limit)
    }

    func weight(of id: Int) -> UInt64 {
        if id == LogicalNamespace.managedGroupID { return namespace.managedAggregate.allocatedBytes }
        guard let physical = namespace.members[id] else { return base.weight(of: id) }
        return physical.reduce(0) { $0 + base.weight(of: $1) }
    }
    /// Reads `weight(of:)` performs.
    private func weighCost(of id: Int) -> Int {
        id == LogicalNamespace.managedGroupID ? 1 : max(1, namespace.members[id]?.count ?? 1)
    }
    func rowCost(of id: Int) -> Int {
        id == LogicalNamespace.managedGroupID ? 1 : (namespace.members[id]?.count ?? base.rowCost(of: id))
    }
    func largestChildren(of parent: Int?, limit: Int) -> (items: [(id: Int, weight: UInt64)], total: Int, cost: Int) {
        guard let total = namespace.listCount(for: parent) else {
            return base.largestChildren(of: parent, limit: limit)
        }
        // Bounded selection over discovery-order pages: never the whole list in memory, never a full sort.
        var selection = HeaviestSelection(limit: limit) { name(of: $0) }
        var cost = 0
        var offset = 0
        while offset < total, let page = namespace.page(for: parent, offset: offset, limit: 512), !page.ids.isEmpty {
            for id in page.ids {
                cost += weighCost(of: id)
                selection.offer(id: id, weight: weight(of: id))
            }
            offset += page.ids.count
        }
        return (selection.ordered(), total, cost)
    }
    func row(for id: Int) -> ScopeRow? { namespace.row(for: id, nodes: nodes) { base.row(for: $0) } }
    func info(of id: Int) -> (name: String, kind: NodeKind)? {
        id == LogicalNamespace.managedGroupID ? (LogicalNamespace.managedGroupName, .directory) : base.info(of: id)
    }
    func sampleCategories(under id: Int, visits: Int) -> (categories: [FileCategory: UInt64]?, consumed: Int) {
        if id == LogicalNamespace.managedGroupID { return (nil, 0) }
        var merged: [FileCategory: UInt64] = [:]
        var consumed = 0
        for member in namespace.physicalMembers(of: id) {
            let left = visits - consumed
            guard left > 0 else { break }
            let part = base.sampleCategories(under: member, visits: left)
            consumed += part.consumed
            for (key, value) in part.categories ?? [:] { merged[key, default: 0] += value }
        }
        return (merged, consumed)
    }
    /// Tie-break name: an in-memory read of an entry selection is already inspecting, not a base-source read.
    private func name(of id: Int) -> String {
        if id == LogicalNamespace.managedGroupID { return LogicalNamespace.managedGroupName }
        return nodes.indices.contains(id) ? nodes[id].name : ""
    }
}

extension ScanResult {
    /// Data aliases map into /; auxiliary roots retain real paths.
    public func logicalPath(for id: Int) -> String? {
        url(for: id).map { StartupDrive.logicalPath($0.path) }
    }
}
