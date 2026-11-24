import Foundation

public struct ScanResult: Sendable {
    public let id: UUID
    public let started: Date
    public private(set) var ended: Date
    public let roots: [URL]
    public let nodes: [ScanNode]
    public var progress: ScanProgress
    public var coverage = LocationCoverage()
    public let volumes: [VolumeContext]
    private let categoryTotals: [ContentClassification: MeasuredCategory]
    /// Unified startup-drive overlay, computed once here on the scanner worker (never on the main actor).
    public let namespace: LogicalNamespace
    private let childIndex: [Int]
    private let childRanges: [Int: Range<Int>]
    private let rootRange: Range<Int>
    private let rootIndices: [Int: Int]
    /// End of the ranked prefix of physical child ranges, and whether the separate root range was ranked.
    private let rankedThrough: Int
    private let rootsRanked: Bool

    public init(
        id: UUID, started: Date, ended: Date, roots: [URL], nodes: [ScanNode],
        progress: ScanProgress, coverage: LocationCoverage = LocationCoverage(), volumes: [VolumeContext]
    ) {
        self.init(
            id: id, started: started, ended: ended, roots: roots, nodes: nodes, progress: progress,
            coverage: coverage, volumes: volumes, navigation: nil)
    }

    init(
        id: UUID, started: Date, ended: Date, roots: [URL], nodes: [ScanNode],
        progress: ScanProgress, coverage: LocationCoverage, volumes: [VolumeContext],
        navigation: consuming ProgressiveIndex?, indexing: (() -> Void)? = nil
    ) {
        self.id = id
        self.started = started
        self.ended = ended
        self.roots = roots
        self.nodes = nodes
        self.progress = progress
        self.coverage = coverage
        self.volumes = volumes
        var rootMap: [Int: Int] = [:]
        for (index, node) in nodes.enumerated() {
            precondition(
                node.id == index && (node.parent.map { $0 >= 0 && $0 < index } ?? true),
                "Nodes must have dense IDs and parents preceding children")
            if node.parent == nil { rootMap[index] = rootMap.count }
        }
        rootIndices = rootMap
        var totals: [ContentClassification: MeasuredCategory] = [:]
        var paths: [String] = []
        var auxiliary: [Bool] = []
        for node in nodes {
            let path = node.parent.map { paths[$0] + "/" + node.name } ?? roots[rootMap[node.id]!].path
            // Policy examines at most four logical components (seven through the Data alias).
            // Retain a bounded prefix, never a full ancestral path per node.
            paths.append("/" + path.split(separator: "/").prefix(7).joined(separator: "/"))
            let isAuxiliary =
                node.parent.map { auxiliary[$0] }
                ?? (coverage.wholeDrive && path != "/" && path != StartupDrive.dataVolumePath)
            auxiliary.append(isAuxiliary)
            let category: ContentClassification = isAuxiliary ? .systemManaged : ScanPolicy().classification(for: path)
            var total = totals[category, default: MeasuredCategory()]
            if node.kind == .file {
                total.logicalBytes += node.logicalBytes
                total.allocatedBytes += node.allocatedBytes
            }
            total.allocationUnknown = total.allocationUnknown || node.allocationUnknown
            totals[category] = total
        }
        categoryTotals = totals
        if var navigation = consume navigation {
            // Only roots need gathering. The scanner already tracks contiguous ranges for every other scope.
            var ids = Array(nodes.indices)
            let ranges = navigation.ranges
            let rootRange: Range<Int>
            if navigation.roots.indices.elementsEqual(navigation.roots) {
                rootRange = 0..<navigation.roots.count
            } else {
                rootRange = ids.count..<(ids.count + navigation.roots.count)
                ids.append(contentsOf: navigation.roots)
            }
            var rankedEnd = 0
            var rankedRoots = false
            var reportIndexing = indexing
            ids.withUnsafeMutableBufferPointer { buffer in
                func rank(_ range: Range<Int>) throws {
                    try Task.checkCancellation()
                    guard range.count > 1 else { return }
                    var children = UnsafeMutableBufferPointer(rebasing: buffer[range])
                    var comparisons = 0
                    try children.sort { a, b in
                        comparisons += 1
                        if comparisons.isMultiple(of: 1024) {
                            reportIndexing.take()?()
                            try Task.checkCancellation()
                        }
                        return nodes[a].precedesInSizeIndex(nodes[b])
                    }
                }
                guard !progress.cancelled else { return }
                do {
                    try rank(rootRange)
                    rankedRoots = true
                    while rankedEnd < nodes.count {
                        if rankedEnd.isMultiple(of: 1024) { try Task.checkCancellation() }
                        if let parent = nodes[rankedEnd].parent, let range = ranges[parent] {
                            if range.count > 1 { try rank(range) }
                            rankedEnd = range.upperBound
                        } else {
                            rankedEnd += 1
                        }
                    }
                } catch {
                    // A throwing sort preserves the elements. Every range still names exactly its own children.
                }
            }
            childIndex = ids
            childRanges = ranges
            self.rootRange = rootRange
            rankedThrough = rankedEnd
            rootsRanked = rankedRoots
            let overlay =
                progress.cancelled
                ? .identity
                : navigation.logicalNamespace(nodes: nodes, urls: roots, coverage: coverage, settled: true)
            if Task.isCancelled { self.progress.state = .cancelled }
            namespace = self.progress.cancelled ? .identity : overlay
        } else {
            // Standalone results also accept trees whose sibling IDs are not contiguous.
            let ids = nodes.indices.sorted { a, b in
                let left = nodes[a]
                let right = nodes[b]
                if left.parent != right.parent { return (left.parent ?? -1) < (right.parent ?? -1) }
                return left.precedesInSizeIndex(right)
            }
            var ranges: [Int: Range<Int>] = [:]
            var start = 0
            while start < ids.count {
                let parent = nodes[ids[start]].parent ?? -1
                var end = start + 1
                while end < ids.count && (nodes[ids[end]].parent ?? -1) == parent { end += 1 }
                ranges[parent] = start..<end
                start = end
            }
            childIndex = ids
            rootRange = ranges.removeValue(forKey: -1) ?? 0..<0
            childRanges = ranges
            rankedThrough = ids.count
            rootsRanked = true
            let rootPaths = rootMap.mapValues { roots[$0].path }
            namespace =
                progress.cancelled
                ? .identity
                : LogicalNamespace.build(nodes: nodes, rootPaths: rootPaths, wholeDrive: coverage.wholeDrive) {
                    parent in
                    ids[ranges[parent] ?? 0..<0]
                }
        }
    }

    /// Commit after the worker has built the topology, before invoking either terminal observer.
    mutating func finish(elapsedSeconds: Double) {
        if Task.isCancelled { progress.state = .cancelled }
        progress.elapsedSeconds = elapsedSeconds
        ended = Date()
    }

    package func childrenAreRanked(of parent: Int?) -> Bool {
        guard let parent else { return rootsRanked || rootRange.count <= 1 }
        guard let range = childRanges[parent] else { return true }
        return range.count <= 1 || range.upperBound <= rankedThrough
    }
    public func measuredCategories() -> [ContentClassification: MeasuredCategory] { categoryTotals }
    /// A shared immutable slice; indices need not start at zero. No node copies or sorting.
    public func childIDs(of id: Int?) -> ArraySlice<Int> {
        guard let id else { return childIndex[rootRange] }
        return childIndex[childRanges[id] ?? 0..<0]
    }
    public func node(for id: Int) -> ScanNode? {
        nodes.indices.contains(id) ? nodes[id] : nil
    }
    /// Compatibility query materializes only the requested scope. Prefer childIDs for UI rows.
    public func children(of id: Int?) -> [ScanNode] {
        childIDs(of: id).map { nodes[$0] }
    }
    public func classification(for id: Int) -> ContentClassification? {
        url(for: id).map { ScanPolicy().classification(for: $0.path) }
    }
    public func eligibility(for id: Int) -> OperationEligibility {
        guard progress.state == .completed || progress.state == .limited,
            nodes.indices.contains(id), nodes[id].kind == .file, let url = url(for: id), !nodes[id].allocationUnknown,
            nodes[id].blocksTrash == false, nodes[id].issue == nil, nodes[id].parent != nil,
            nodes[id].hardLinkOwner == nil,
            TrashTarget.personalLocation(url)
        else { return .inspectionOnly }
        return ScanPolicy().eligibility(for: url.path, kind: nodes[id].kind)
    }
    /// Same row value the progressive path publishes, for settled navigation.
    public func scopeRow(for id: Int) -> ScopeRow? {
        guard let node = node(for: id), let status = coverageStatus(for: id) else { return nil }
        return ScopeRow(
            node: node, classification: classification(for: id) ?? .personal, coverage: status,
            enumeration: coverage.enumeration[id], eligibility: eligibility(for: id))
    }
    /// Breadcrumbs and authoritative totals for a settled scope. nil parent is the root list.
    public func scopeSummary(parent: Int?) -> ScopeSummary {
        guard let parent, nodes.indices.contains(parent) else {
            let roots = childIDs(of: nil)
            return ScopeSummary(
                crumbs: [], logicalBytes: roots.reduce(0) { $0 + nodes[$1].logicalBytes },
                allocatedBytes: roots.reduce(0) { $0 + nodes[$1].allocatedBytes },
                allocationUnknown: coverage.reasonCounts[.unresolvedVolume, default: 0] > 0
                    || roots.contains { nodes[$0].allocationUnknown },
                issue: nil, enumeration: nil)
        }
        var chain: [ScopeCrumb] = []
        var cursor: Int? = parent
        while let id = cursor {
            chain.append(ScopeCrumb(id: id, name: nodes[id].name))
            cursor = nodes[id].parent
        }
        return ScopeSummary(
            crumbs: chain.reversed(), logicalBytes: nodes[parent].logicalBytes,
            allocatedBytes: nodes[parent].allocatedBytes,
            allocationUnknown: nodes[parent].allocationUnknown,
            issue: nodes[parent].issue, enumeration: coverage.enumeration[parent])
    }
    public func url(for id: Int) -> URL? {
        guard nodes.indices.contains(id) else { return nil }
        var components: [String] = []
        var cursor = id
        while let parent = nodes[cursor].parent {
            components.append(nodes[cursor].name)
            cursor = parent
        }
        guard let index = rootIndices[cursor], roots.indices.contains(index) else { return nil }
        return components.reversed().reduce(roots[index]) { $0.appendingPathComponent($1) }
    }
}

public enum NodeCoverageStatus: Sendable { case measured, partial, policyExcluded, denied, unavailable, notYetScanned }
extension NodeCoverageStatus {
    /// The one rule for how fully a node was read. A node issue decides it; otherwise a folder not yet opened is not
    /// scanned yet, and unknown allocation (unread contents, or a provisional total) is partial.
    init(issue: CoverageIssue?, enumeration: DirectoryEnumeration?, allocationUnknown: Bool) {
        switch issue {
        case .policyExcluded?, .volumeBoundary?: self = .policyExcluded
        case .denied?: self = .denied
        case .some: self = .unavailable
        case nil:
            if enumeration == .unopened {
                self = .notYetScanned
            } else {
                self = allocationUnknown ? .partial : .measured
            }
        }
    }
}
extension ScanResult {
    public func coverageStatus(for id: Int) -> NodeCoverageStatus? {
        guard nodes.indices.contains(id) else { return nil }
        return NodeCoverageStatus(
            issue: nodes[id].issue, enumeration: coverage.enumeration[id],
            allocationUnknown: nodes[id].allocationUnknown)
    }
}

public struct MeasuredCategory: Sendable {
    public var logicalBytes: UInt64 = 0
    public var allocatedBytes: UInt64 = 0
    public var allocationUnknown = false
}
