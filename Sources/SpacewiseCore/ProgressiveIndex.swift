import Foundation

/// One unit of index work, reported to a `ProgressiveIndexObserver`.
enum ProgressiveIndexWork: Sendable {
    /// Physical roots summarized for one top-level snapshot.
    case rootSummary(visits: Int)
    /// A full construction of the namespace (the first, plus any explicit invalidation or root-path change) over
    /// `nodes`.
    case namespaceBuild(nodes: Int)
    /// Nodes admitted incrementally after construction.
    case namespaceAppend(nodes: Int)
    /// One child admitted to a name group, including bootstrap of newly merged folders (all construction work).
    case namespaceVisit
    /// One name group re-evaluated.
    case namespaceReconcile
    /// The managed aggregate recomputed from finalized nodes (once per settled scan, never per query), reading
    /// `roots` physical roots.
    case namespaceSettle(roots: Int)
}

/// Observes the index's work. A scan installs none, so nothing is counted on the scan path; regression tests
/// install a counter to prove that work stays proportional to what was appended.
protocol ProgressiveIndexObserver: AnyObject, Sendable {
    func indexDidWork(_ work: ProgressiveIndexWork)
}

/// Owned exclusively by the scanner. Ranges rely on its single-directory enumeration order. Package-visible so
/// the test fixtures can build live snapshots the way the scanner does.
package struct ProgressiveIndex {
    var ranges: [Int: Range<Int>] = [:]
    var roots: [Int] = []
    /// Direct children still waiting for a complete measurement (or terminally unknown).
    private var unresolvedChildren: [Int: Int] = [:]
    package var totals: [Int: (logical: UInt64, allocated: UInt64)] = [:]
    /// Worker-owned incremental namespace. Never copied into a snapshot: bounded pages and maps are built
    /// synchronously and release their aliases before the next append, so mutation never detaches its buffers.
    private var builder: NamespaceBuilder?
    var namespaceChildren: (@Sendable (Int) -> Void)?
    /// Nil outside tests. Passed to each namespace builder the index creates.
    var observer: (any ProgressiveIndexObserver)?
    /// Drop the cache so the next query rebuilds it. Only for a discarded or inconsistent cache; ordinary metadata
    /// changes use `entryChanged`.
    mutating func invalidateNamespace() { builder = nil }
    /// A node already admitted changed metadata that can affect how its name group presents it.
    mutating func entryChanged(_ id: Int) { builder?.entryChanged(id) }
    package init() {}
    package mutating func append(_ node: ScanNode) {
        if let parent = node.parent {
            if node.kind == .directory || node.kind == .package || node.allocationUnknown || node.issue != nil {
                unresolvedChildren[parent, default: 0] += 1
            }
            let start = ranges[parent]?.lowerBound ?? node.id
            precondition(ranges[parent].map { $0.upperBound == node.id } ?? true)
            ranges[parent] = start..<(node.id + 1)
        } else {
            roots.append(node.id)
        }
    }
    /// A completed listing can finish its already-listed ancestors. Each directory resolves once.
    mutating func finishedListing(_ folder: Int, nodes: [ScanNode], coverage: LocationCoverage) {
        var child = folder
        while coverage.enumeration[child] == .enumerated, unresolvedChildren[child] == nil,
            !nodes[child].allocationUnknown, nodes[child].issue == nil, let parent = nodes[child].parent,
            let remaining = unresolvedChildren[parent]
        {
            unresolvedChildren[parent] = remaining == 1 ? nil : remaining - 1
            child = parent
        }
    }

    /// Signed byte delta along the ancestor chain. The managed aggregate follows the same deltas through the one
    /// managed physical root an ancestor chain can contain, so it stays equal to the sum of its roots' totals.
    package mutating func attribute(
        logical: UInt64, allocated: UInt64, to parent: Int?, nodes: [ScanNode],
        subtract: Bool = false
    ) {
        guard logical != 0 || allocated != 0 else { return }
        var cursor = parent
        while let id = cursor {
            builder?.attribute(id, logical: logical, allocated: allocated, subtract: subtract)
            let old = totals[id] ?? (0, 0)
            totals[id] =
                subtract
                ? (old.logical - logical, old.allocated - allocated)
                : (old.logical + logical, old.allocated + allocated)
            cursor = nodes[id].parent
        }
    }
    package mutating func snapshot(
        scanID: UUID, revision: UInt64, request: ScopeRequest, nodes: [ScanNode],
        urls: [URL], coverage: LocationCoverage, progress: ScanProgress,
        includeTreemap: Bool = false
    ) -> ScopeSnapshot {
        let namespace = logicalNamespace(
            nodes: nodes, urls: urls, coverage: coverage,
            settled: progress.state != .scanning)
        let base = ProvisionalTreemapSource(
            index: self, nodes: nodes, urls: urls, coverage: coverage, progress: progress)
        if namespace.unified {
            // One drive rooted at /: merged folders, the unified root and the managed group list logical entries.
            let source = LogicalTreemapSource(base: base, namespace: namespace, nodes: nodes)
            let logicalRows: [ScopeRow]
            let count: Int
            if let page = namespace.page(for: request.parent, offset: request.offset, limit: ScopeSnapshot.pageSize) {
                logicalRows = page.ids.compactMap(source.row(for:))
                count = page.total
            } else {
                let range = request.parent.flatMap { ranges[$0] } ?? 0..<0
                let offset = min(request.offset, range.count)
                let end = offset + min(ScopeSnapshot.pageSize, range.count - offset)
                logicalRows = (offset..<end).compactMap { source.row(for: range.lowerBound + $0) }
                count = range.count
            }
            let scanning = progress.state == .scanning
            if request.parent == nil { observer?.indexDidWork(.rootSummary(visits: roots.count)) }
            let summary =
                request.parent == nil
                ? self.summary(for: nil, nodes: nodes, coverage: coverage, progress: progress)
                : namespace.summary(
                    parent: request.parent, nodes: nodes, base: base.row(for:), scanning: scanning,
                    issue: { nodes.indices.contains($0) ? nodes[$0].issue : nil },
                    enumeration: { coverage.enumeration[$0] })
            let treemap =
                includeTreemap
                ? TreemapBuilder.build(source: source, scope: request.parent, provisional: scanning, limits: .live)
                : nil
            return ScopeSnapshot(
                scanID: scanID, revision: revision, request: request,
                parentOfScope: request.parent.flatMap { namespace.parent(of: $0, nodes: nodes) },
                scope: summary, rows: logicalRows, discoveredChildren: count,
                enumeration: request.parent.flatMap {
                    nodes.indices.contains($0) ? coverage.enumeration[$0] : nil
                },
                provisional: scanning, progress: progress, treemap: treemap)
        }
        let range = request.parent.flatMap { ranges[$0] } ?? 0..<0
        let count = request.parent == nil ? roots.count : range.count
        let offset = min(request.offset, count)
        let end = offset + min(ScopeSnapshot.pageSize, count - offset)
        let rows = (offset..<end).map { position -> ScopeRow in
            provisionalRow(
                id: request.parent == nil ? roots[position] : range.lowerBound + position,
                nodes: nodes, urls: urls, coverage: coverage, progress: progress)
        }
        let treemap =
            includeTreemap
            ? TreemapBuilder.build(
                source: base, scope: request.parent, provisional: progress.state == .scanning,
                limits: .live)
            : nil
        return ScopeSnapshot(
            scanID: scanID, revision: revision, request: request,
            parentOfScope: request.parent.flatMap { nodes.indices.contains($0) ? nodes[$0].parent : nil },
            scope: summary(for: request.parent, nodes: nodes, coverage: coverage, progress: progress),
            rows: rows, discoveredChildren: count,
            enumeration: request.parent.flatMap { coverage.enumeration[$0] },
            provisional: progress.state == .scanning, progress: progress, treemap: treemap)
    }
    /// Worker-owned topology only; totals continue to be read from the current node store. Admits the nodes appended
    /// since the previous call (work proportional to them), polling cancellation; a cancelled call returns identity
    /// without discarding the coherent cache. `settled` refreshes the managed aggregate once from finalized nodes.
    mutating func logicalNamespace(
        nodes: [ScanNode], urls: [URL], coverage: LocationCoverage,
        settled: Bool = false
    ) -> LogicalNamespace {
        guard !Task.isCancelled else { return .identity }
        guard coverage.wholeDrive else { return .identity }
        var rootPaths: [Int: String] = [:]
        for (position, id) in roots.enumerated() where urls.indices.contains(position) {
            rootPaths[id] = urls[position].path
        }
        // Closures read copies of the index storage; nothing mutates it while the builder runs.
        let ranges = self.ranges
        let totals = self.totals
        let hook = namespaceChildren
        let environment = NamespaceBuilder.Environment(
            nodes: nodes, cancelled: { Task.isCancelled },
            bytes: { id in
                totals[id].map { ($0.logical, $0.allocated) } ?? (nodes[id].logicalBytes, nodes[id].allocatedBytes)
            },
            children: { parent, limit in
                hook?(parent)
                guard let range = ranges[parent] else { return [] }
                let upper = min(range.upperBound, limit)
                return range.lowerBound < upper ? Array(range.lowerBound..<upper) : []
            })
        for attempt in 0..<2 {
            // The builder is moved out while it works, so it stays uniquely referenced and mutates in place, and is
            // put back on every outcome that keeps it.
            let created = builder == nil
            var current = builder.take() ?? NamespaceBuilder(observer: observer)
            if created { observer?.indexDidWork(.namespaceBuild(nodes: nodes.count)) }
            let before = current.fed
            let outcome = current.advance(environment, rootPaths: rootPaths)
            if !created { observer?.indexDidWork(.namespaceAppend(nodes: current.fed - before)) }
            switch outcome {
            case .cancelled:
                builder = current
                return .identity
            case .rebuild:
                // A known root changed path: root metadata cannot be patched, so rebuild once (never per checkpoint).
                if attempt == 1 { return .identity }
                continue
            case .done:
                if settled { current.settleAggregate(nodes: nodes) }
                builder = current
                return current.view
            }
        }
        return .identity
    }
    /// One row with provisional totals applied. Shared by bounded pages and the storage map.
    func provisionalRow(
        id: Int, nodes: [ScanNode], urls: [URL], coverage: LocationCoverage,
        progress: ScanProgress
    ) -> ScopeRow {
        var node = nodes[id]
        if progress.state == .scanning, let enumeration = coverage.enumeration[id] {
            // A listed subtree with every child accounted for includes a genuine measured zero.
            if enumeration != .enumerated || unresolvedChildren[id] != nil { node.allocationUnknown = true }
        }
        if progress.state == .scanning, let total = totals[id] {
            node.logicalBytes = total.logical
            node.allocatedBytes = total.allocated
        }
        var cursor = id
        var names: [String] = []
        while let parent = nodes[cursor].parent {
            names.append(nodes[cursor].name)
            cursor = parent
        }
        let root = roots.firstIndex(of: cursor).flatMap { urls.indices.contains($0) ? urls[$0] : nil }
        let path = names.reversed().reduce(root ?? URL(fileURLWithPath: "/")) { $0.appendingPathComponent($1) }.path
        // `allocationUnknown` already carries the provisional skew applied above.
        let state = NodeCoverageStatus(
            issue: node.issue, enumeration: coverage.enumeration[id],
            allocationUnknown: node.allocationUnknown)
        return ScopeRow(
            node: node, classification: ScanPolicy().classification(for: path), coverage: state,
            enumeration: coverage.enumeration[id])
    }
    /// O(depth) plus O(roots). Provisional totals come from the incremental index; settled totals from nodes.
    func summary(
        for parent: Int?, nodes: [ScanNode], coverage: LocationCoverage,
        progress: ScanProgress
    ) -> ScopeSummary {
        let scanning = progress.state == .scanning
        func known(_ id: Int) -> (UInt64, UInt64) {
            scanning
                ? (totals[id]?.logical ?? 0, totals[id]?.allocated ?? 0)
                : (nodes[id].logicalBytes, nodes[id].allocatedBytes)
        }
        guard let parent, nodes.indices.contains(parent) else {
            var logical: UInt64 = 0
            var allocated: UInt64 = 0
            var unknown = scanning || coverage.reasonCounts[.unresolvedVolume, default: 0] > 0
            for root in roots {
                let value = known(root)
                logical += value.0
                allocated += value.1
                unknown = unknown || nodes[root].allocationUnknown
            }
            return ScopeSummary(
                crumbs: [], logicalBytes: logical, allocatedBytes: allocated, allocationUnknown: unknown,
                issue: nil, enumeration: nil)
        }
        var chain: [ScopeCrumb] = []
        var cursor: Int? = parent
        while let id = cursor {
            chain.append(ScopeCrumb(id: id, name: nodes[id].name))
            cursor = nodes[id].parent
        }
        let value = known(parent)
        let pending = coverage.enumeration[parent].map { $0 != .enumerated } ?? false
        return ScopeSummary(
            crumbs: chain.reversed(), logicalBytes: value.0, allocatedBytes: value.1,
            allocationUnknown: nodes[parent].allocationUnknown || pending || nodes[parent].issue != nil
                || scanning,
            issue: nodes[parent].issue, enumeration: coverage.enumeration[parent])
    }
}

/// Provisional storage-map reads over the scanner's incremental index. One pass per expanded folder, charged to
/// the build's cost budget; a folder with millions of children is not expanded rather than stalling a checkpoint.
struct ProvisionalTreemapSource: TreemapSource {
    let index: ProgressiveIndex
    let nodes: [ScanNode]
    let urls: [URL]
    let coverage: LocationCoverage
    let progress: ScanProgress

    func selectionCost(of parent: Int?) -> Int {
        parent.map { index.ranges[$0]?.count ?? 0 } ?? index.roots.count
    }
    var rootWeight: UInt64 { index.roots.reduce(0) { $0 + weight(of: $1) } }

    func weight(of id: Int) -> UInt64 {
        guard nodes.indices.contains(id) else { return 0 }
        if progress.state == .scanning, let total = index.totals[id] { return total.allocated }
        return nodes[id].allocatedBytes
    }
    func largestChildren(of parent: Int?, limit: Int) -> (items: [(id: Int, weight: UInt64)], total: Int, cost: Int) {
        // Bounded selection straight over the child range: no copy of the range, no whole-list sort.
        var selection = HeaviestSelection(limit: limit) { nodes[$0].name }
        var total = 0
        if let parent {
            for id in index.ranges[parent] ?? 0..<0 {
                total += 1
                selection.offer(id: id, weight: weight(of: id))
            }
        } else {
            for id in index.roots {
                total += 1
                selection.offer(id: id, weight: weight(of: id))
            }
        }
        return (selection.ordered(), total, total)
    }
    func info(of id: Int) -> (name: String, kind: NodeKind)? {
        nodes.indices.contains(id) ? (nodes[id].name, nodes[id].kind) : nil
    }
    func row(for id: Int) -> ScopeRow? {
        guard nodes.indices.contains(id) else { return nil }
        return index.provisionalRow(id: id, nodes: nodes, urls: urls, coverage: coverage, progress: progress)
    }
}
