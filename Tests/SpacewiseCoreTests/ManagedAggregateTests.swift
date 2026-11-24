import Foundation
import Testing

@testable import SpacewiseCore

// The managed aggregate (the "System & managed" group) stays exact and constant-cost to query while a scan grows and
// after it settles, including late merges, late roots and hard-link ownership transfers. Work counters, not wall-clock
// time, are the gates.

struct ManagedAggregateTests {
    /// 3,000 auxiliary volume roots, each holding two files, all inside the managed group.
    private func broadManaged(roots count: Int) -> (
        nodes: [ScanNode], urls: [String], expected: (logical: UInt64, allocated: UInt64)
    ) {
        var tree = Tree()
        tree.root("/")
        tree.root("/System/Volumes/Data")
        var paths: [String] = []
        var logical: UInt64 = 0
        var allocated: UInt64 = 0
        var rootIDs: [Int] = []
        for n in 0..<count {
            rootIDs.append(tree.root("/Volumes/V\(n)"))
            paths.append("/Volumes/V\(n)")
        }
        for (n, id) in rootIDs.enumerated() {
            for f in 0..<2 {
                let bytes = UInt64(4096 * (1 + (n + f) % 9))
                tree.add(id, "file\(f)", .file, bytes: bytes)
                logical += bytes - 7
                allocated += bytes
            }
        }
        return (tree.nodes, paths, (logical, allocated))
    }

    @Test func managedQueriesAreConstantCostWhileScanningAndSettled() {
        let fixture = broadManaged(roots: 3000)
        var nodes = fixture.nodes
        var index = ProgressiveIndex.counted()
        // Roots first, then each root's children, as the scanner enumerates them.
        admit(&index, nodes, 0..<nodes.count)
        var progress = ScanProgress()
        progress.state = .scanning
        func snapshot(_ scope: Int?, _ state: ScanState) -> ScopeSnapshot {
            progress.state = state
            return index.snapshot(
                scanID: UUID(), revision: 1, request: ScopeRequest(parent: scope), nodes: nodes,
                urls: [systemURL, dataURL] + fixture.urls.map { URL(fileURLWithPath: $0) }, coverage: wholeDrive,
                progress: progress)
        }
        let first = snapshot(managedGroup, .scanning)
        #expect(
            first.scope.allocatedBytes == fixture.expected.allocated
                && first.scope.logicalBytes == fixture.expected.logical)
        #expect(first.scope.allocationUnknown && first.provisional)
        let visits = index.namespaceVisitCount
        let reconciles = index.namespaceReconcileCount
        #expect(index.namespaceBuildCount == 1 && index.namespaceSettleCount == 0)
        for scope in [managedGroup, nil, managedGroup, nil] + [Int?](repeating: managedGroup, count: 100) {
            let value = snapshot(scope, .scanning)
            if scope == managedGroup { #expect(value.scope.allocatedBytes == fixture.expected.allocated) }
        }
        // Repeated progressive queries read no membership: no topology work, no rebuild, no recomputation.
        #expect(index.namespaceVisitCount == visits && index.namespaceReconcileCount == reconciles)
        #expect(index.namespaceBuildCount == 1 && index.namespaceSettleCount == 0)

        // Settle: finalize nodes exactly as the scanner does, then query the settled state repeatedly.
        nodes = finalize(nodes, coverage: enumeratedCoverage(of: nodes))
        for _ in 0..<200 {
            let value = snapshot(managedGroup, .completed)
            #expect(
                value.scope.allocatedBytes == fixture.expected.allocated
                    && value.scope.logicalBytes == fixture.expected.logical)
            #expect(!value.scope.allocationUnknown)
        }
        #expect(index.namespaceSettleCount == 1)
        #expect(index.namespaceVisitCount == visits)
    }

    @Test func nodeRowSummaryAndWeightNeverReadMembers() {
        let fixture = broadManaged(roots: 3000)
        var index = ProgressiveIndex()
        admit(&index, fixture.nodes, 0..<fixture.nodes.count)
        let ns = namespace(&index, fixture.nodes, auxiliary: fixture.urls)
        var reads = 0
        for _ in 0..<500 {
            let row = ns.row(for: managedGroup, nodes: fixture.nodes) { _ in
                reads += 1
                return nil
            }
            let node = ns.node(
                for: managedGroup, nodes: fixture.nodes,
                read: { _ in
                    reads += 1
                    return nil
                })
            let summary = ns.summary(
                parent: managedGroup, nodes: fixture.nodes,
                base: { _ in
                    reads += 1
                    return nil
                }, scanning: true,
                issue: { _ in nil }, enumeration: { _ in nil })
            #expect(
                row?.node.allocatedBytes == fixture.expected.allocated
                    && node?.allocatedBytes == fixture.expected.allocated)
            #expect(
                row?.node.logicalBytes == fixture.expected.logical
                    && summary.allocatedBytes == fixture.expected.allocated)
        }
        let source = LogicalTreemapSource(
            base: CountingSource(
                base: ProvisionalTreemapSource(
                    index: index, nodes: fixture.nodes, urls: [], coverage: wholeDrive, progress: ScanProgress())),
            namespace: ns, nodes: fixture.nodes)
        for _ in 0..<500 { #expect(source.weight(of: managedGroup) == fixture.expected.allocated) }
        #expect(reads == 0 && source.base.counter.total == 0)
    }

    @Test func aggregateFollowsAppendsLateMergesAndLateRoots() {
        var tree = Tree()
        let system = tree.root("/")
        let data = tree.root("/System/Volumes/Data")
        var index = ProgressiveIndex.counted()
        admit(&index, tree.nodes, 0..<2)
        func aggregate() -> (UInt64, UInt64, Bool) {
            let ns = namespace(&index, tree.nodes)
            return (
                ns.managedAggregate.logicalBytes, ns.managedAggregate.allocatedBytes,
                ns.managedAggregate.allocationUnknown
            )
        }
        var state = aggregate()
        #expect(state.0 == 0 && state.1 == 0 && state.2, "empty membership is zero but unknown until settled")

        // Append after the cache exists: a managed top-level folder with a file, then more files in it.
        let sys = tree.add(system, "System")
        let usr = tree.add(system, "usr")
        let a = tree.add(sys, "a.bin", .file, bytes: 8192)
        admit(&index, tree.nodes, 2..<tree.nodes.count)
        state = aggregate()
        #expect(state.1 == 8192 && state.2)
        let b = tree.add(sys, "b.bin", .file, bytes: 4096)
        let c = tree.add(usr, "c.bin", .file, bytes: 16384)
        _ = (a, b, c)
        admit(&index, tree.nodes, tree.nodes.count - 2..<tree.nodes.count)
        // The folders' children must be contiguous: `b` belongs to System and `c` to usr, each appended in turn.
        state = aggregate()
        #expect(state.1 == 8192 + 4096 + 16384 && state.0 == (8192 - 7) + (4096 - 7) + (16384 - 7))

        // Late managed merge: the Data twin of System appears after bytes are already attributed to the first side.
        let dataSys = tree.add(data, "System")
        admit(&index, tree.nodes, tree.nodes.count - 1..<tree.nodes.count)
        tree.add(dataSys, "d.bin", .file, bytes: 32768)
        admit(&index, tree.nodes, tree.nodes.count - 1..<tree.nodes.count)
        let merged = namespace(&index, tree.nodes)
        #expect(merged.members[sys] == [sys, dataSys] && merged.managedPhysicalRoots == [sys, usr, dataSys])
        #expect(merged.managedAggregate.allocatedBytes == 8192 + 4096 + 16384 + 32768)
        #expect(
            index.totals[sys]!.allocated + index.totals[usr]!.allocated + index.totals[dataSys]!.allocated
                == merged.managedAggregate.allocatedBytes)

        // A bytes delta after the merge reaches the aggregate through whichever member it lands in.
        tree.add(dataSys, "e.bin", .file, bytes: 4096)
        admit(&index, tree.nodes, tree.nodes.count - 1..<tree.nodes.count)
        #expect(aggregate().1 == 8192 + 4096 + 16384 + 32768 + 4096)
        #expect(index.namespaceBuildCount == 1)
    }

    @Test func settledAggregateUsesFinalizedNodesAndUnknownState() {
        func settle(enumeration: DirectoryEnumeration, state: ScanState) -> ScopeSummary {
            var tree = Tree()
            let system = tree.root("/")
            tree.root("/System/Volumes/Data")
            let sys = tree.add(system, "System")
            tree.add(sys, "a.bin", .file, bytes: 8192)
            var index = ProgressiveIndex()
            admit(&index, tree.nodes, 0..<tree.nodes.count)
            let coverage = enumeratedCoverage(of: tree.nodes, unfinished: [sys: enumeration])
            let nodes = finalize(tree.nodes, coverage: coverage)
            var progress = ScanProgress()
            progress.state = state
            return index.snapshot(
                scanID: UUID(), revision: 1, request: ScopeRequest(parent: managedGroup), nodes: nodes,
                urls: [systemURL, dataURL], coverage: coverage, progress: progress
            ).scope
        }
        let complete = settle(enumeration: .enumerated, state: .completed)
        #expect(complete.allocatedBytes == 8192 && !complete.allocationUnknown)
        // An unopened directory keeps the group a lower bound; so does a cancelled one. Never a complete claim.
        let unopened = settle(enumeration: .unopened, state: .limited)
        #expect(unopened.allocatedBytes == 8192 && unopened.allocationUnknown)
        let cancelled = settle(enumeration: .cancelled, state: .cancelled)
        #expect(cancelled.allocatedBytes == 8192 && cancelled.allocationUnknown)
    }

    @Test func issueOnlyAuxiliaryRootAndUnknownChildKeepTheGroupUnknown() {
        var tree = Tree()
        tree.root("/")
        tree.root("/System/Volumes/Data")
        let denied = tree.root("/Volumes/Denied")
        tree.nodes[denied].issue = .denied  // no allocationUnknown flag: the issue alone must be enough
        let good = tree.root("/Volumes/Good")
        tree.add(good, "x.bin", .file, bytes: 4096)
        var index = ProgressiveIndex()
        admit(&index, tree.nodes, 0..<tree.nodes.count)
        let urls = [systemURL, dataURL, URL(fileURLWithPath: "/Volumes/Denied"), URL(fileURLWithPath: "/Volumes/Good")]
        var progress = ScanProgress()
        progress.state = .limited
        // Finalized by hand so only the issue (not an allocationUnknown flag) can make the group unknown.
        var finalized = tree.nodes
        finalized[good].allocatedBytes = 4096
        finalized[good].logicalBytes = 4089
        let value = index.snapshot(
            scanID: UUID(), revision: 1, request: ScopeRequest(parent: managedGroup), nodes: finalized, urls: urls,
            coverage: wholeDrive, progress: progress)
        #expect(value.scope.allocatedBytes == 4096 && value.scope.allocationUnknown)

        // The same group without the denied root is complete.
        var clean = Tree()
        clean.root("/")
        clean.root("/System/Volumes/Data")
        let only = clean.root("/Volumes/Good")
        clean.add(only, "x.bin", .file, bytes: 4096)
        var cleanIndex = ProgressiveIndex()
        admit(&cleanIndex, clean.nodes, 0..<clean.nodes.count)
        let nodes = finalize(clean.nodes, coverage: wholeDrive)
        let known = cleanIndex.snapshot(
            scanID: UUID(), revision: 1, request: ScopeRequest(parent: managedGroup), nodes: nodes,
            urls: [systemURL, dataURL, URL(fileURLWithPath: "/Volumes/Good")], coverage: wholeDrive, progress: progress)
        #expect(known.scope.allocatedBytes == 4096 && !known.scope.allocationUnknown)
    }

    /// Replays the scanner's ownership transfer: subtract the old owner's bytes from its ancestry before zeroing,
    /// zero it, then attribute the new owner's bytes to its ancestry.
    private func transfer(_ index: inout ProgressiveIndex, _ tree: inout Tree, owner: Int, newParent: Int, name: String)
        -> Int
    {
        index.attribute(
            logical: tree.nodes[owner].logicalBytes, allocated: tree.nodes[owner].allocatedBytes,
            to: tree.nodes[owner].parent, nodes: tree.nodes, subtract: true)
        let bytes = tree.nodes[owner].allocatedBytes
        tree.nodes[owner].logicalBytes = 0
        tree.nodes[owner].allocatedBytes = 0
        let id = tree.add(newParent, name, .file, bytes: bytes)
        admit(&index, tree.nodes, id..<(id + 1))
        return id
    }

    @Test func hardlinkOwnershipTransfersKeepTheAggregateExact() {
        // Layout: / has System (managed), usr (managed) and Users (outside); each starts with one file.
        func scenario(from: String, to: String, expectBefore: UInt64, expectAfter: UInt64) {
            var tree = Tree()
            let system = tree.root("/")
            tree.root("/System/Volumes/Data")
            let folders = [
                "System": tree.add(system, "System"), "usr": tree.add(system, "usr"),
                "Users": tree.add(system, "Users"),
            ]
            let owner = tree.add(folders[from]!, "z-link", .file, bytes: 12288)
            var index = ProgressiveIndex()
            admit(&index, tree.nodes, 0..<tree.nodes.count)
            #expect(
                namespace(&index, tree.nodes).managedAggregate.allocatedBytes == expectBefore, "before \(from) → \(to)")
            let newOwner = transfer(&index, &tree, owner: owner, newParent: folders[to]!, name: "a-link")
            let ns = namespace(&index, tree.nodes)
            #expect(
                ns.managedAggregate.allocatedBytes == expectAfter
                    && ns.managedAggregate.logicalBytes == (expectAfter == 0 ? 0 : 12288 - 7), "after \(from) → \(to)")
            // Progress and namespace reconcile: the aggregate equals the managed roots' totals and the finalized nodes.
            #expect(ns.managedPhysicalRoots.reduce(0) { $0 + (index.totals[$1]?.allocated ?? 0) } == expectAfter)
            let nodes = finalize(tree.nodes, coverage: wholeDrive)
            let settled = namespace(&index, nodes, settled: true)
            #expect(settled.managedAggregate.allocatedBytes == expectAfter)
            #expect(oracle(index, nodes).managedAggregate.allocatedBytes == expectAfter)
            _ = newOwner
        }
        scenario(from: "Users", to: "System", expectBefore: 0, expectAfter: 12288)  // outside → managed
        scenario(from: "System", to: "Users", expectBefore: 12288, expectAfter: 0)  // managed → outside
        scenario(from: "System", to: "System", expectBefore: 12288, expectAfter: 12288)  // same group: nets zero
        scenario(from: "System", to: "usr", expectBefore: 12288, expectAfter: 12288)  // managed → managed
    }

    @Test func sparseAndUnknownAliasesAddNoBytesAndKeepUnknownState() {
        var tree = Tree()
        let system = tree.root("/")
        tree.root("/System/Volumes/Data")
        let sys = tree.add(system, "System")
        tree.add(sys, "real.bin", .file, bytes: 8192)
        // Alias / sparse: no allocated bytes, unknown allocation.
        tree.add(sys, "alias.bin", .file, bytes: 0, unknown: true)
        var index = ProgressiveIndex()
        admit(&index, tree.nodes, 0..<tree.nodes.count)
        let ns = namespace(&index, tree.nodes)
        #expect(ns.managedAggregate.allocatedBytes == 8192)
        let nodes = finalize(tree.nodes, coverage: enumeratedCoverage(of: tree.nodes))
        let settled = namespace(&index, nodes, settled: true)
        #expect(settled.managedAggregate.allocatedBytes == 8192 && settled.managedAggregate.allocationUnknown)
    }
}
