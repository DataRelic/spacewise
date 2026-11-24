import Foundation
import Synchronization
import Testing

@testable import SpacewiseCore

// B: growing merged namespaces reconcile incrementally. Gates are visit counters and equivalence with the existing
// full-build oracle, never wall-clock time.

final class PollCounter { var value = 0 }

struct NamespaceGrowthTests {
    /// Feeds `tree` to a fresh index in batches, checkpointing after each batch like the scanner's 200 ms publication.
    private func grow(_ tree: Tree, batch: Int, snapshots: Bool = false) -> (
        index: ProgressiveIndex, namespace: LogicalNamespace, checkpoints: Int
    ) {
        var index = ProgressiveIndex.counted()
        var last = LogicalNamespace.identity
        var fed = 0
        var checkpoints = 0
        while fed < tree.nodes.count {
            let next = min(tree.nodes.count, fed + batch)
            admit(&index, tree.nodes, fed..<next)
            let nodes = Array(tree.nodes.prefix(next))
            if snapshots {
                var progress = ScanProgress()
                progress.state = .scanning
                let value = index.snapshot(
                    scanID: UUID(), revision: UInt64(checkpoints + 1),
                    request: ScopeRequest(parent: nil, wantsTreemap: true), nodes: nodes,
                    urls: [systemURL, dataURL], coverage: wholeDrive, progress: progress, includeTreemap: true)
                #expect(value.rows.count <= ScopeSnapshot.pageSize)
                if let map = value.treemap {
                    #expect(
                        map.tiles.count <= TreemapLimits.live.maxTiles && map.stats.cost <= TreemapLimits.live.maxCost)
                }
            }
            last = namespace(&index, nodes)
            fed = next
            checkpoints += 1
        }
        return (index, last, checkpoints)
    }

    @Test func pairedGrowthWorkIsLinearInAdmittedChildrenNotCheckpoints() {
        let tree = pairedTree(top: 40, subs: 25, files: 3)  // 8,082 physical nodes
        let admitted = tree.nodes.count - 2  // every non-root node is admitted to exactly one name group
        var results: [(visits: Int, reconciles: Int, checkpoints: Int)] = []
        for batch in [97, 800, 8_082] {
            let run = grow(tree, batch: batch, snapshots: batch == 800)
            #expect(run.index.namespaceBuildCount == 1, "batch \(batch)")
            #expect(run.index.namespaceVisitCount == admitted, "batch \(batch): every child admitted exactly once")
            #expect(run.index.namespaceAppendWorkCount <= tree.nodes.count)
            expectEquivalent(run.namespace, oracle(run.index, tree.nodes), nodes: tree.nodes, "batch \(batch)")
            results.append((run.index.namespaceVisitCount, run.index.namespaceReconcileCount, run.checkpoints))
        }
        // Many checkpoints cost the same topology work as one: not checkpoints × discovered count.
        #expect(
            Set(results.map(\.visits)).count == 1
                && results.map(\.checkpoints) == [results[0].checkpoints, results[1].checkpoints, 1])
        #expect(results[0].checkpoints > 80 && results[0].reconciles == results[2].reconciles)
    }

    @Test func mergedPagesFollowDiscoveryOrderAndStaySliceable() throws {
        let tree = pairedTree(top: 6, subs: 4, files: 2)
        let run = grow(tree, batch: 5)
        let merged = try #require(run.namespace.members.keys.min())
        let all = try #require(run.namespace.list(for: merged))
        #expect(all.count == 4)
        for offset in 0...(all.count + 1) {
            let page = try #require(run.namespace.page(for: merged, offset: offset, limit: 3))
            #expect(page.total == all.count && page.ids == Array(all.dropFirst(offset).prefix(3)))
        }
        // First-discovery order: sub0, sub1, ... by the first physical entry of each name.
        #expect(all.compactMap { tree.nodes[$0].name } == ["sub0", "sub1", "sub2", "sub3"])
    }

    // MARK: Identity against the full-build oracle

    private func compareEveryStep(
        _ tree: Tree, auxiliary: [String] = [], from start: Int = 2, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var index = ProgressiveIndex.counted()
        admit(&index, tree.nodes, 0..<start)
        for k in start..<tree.nodes.count {
            admit(&index, tree.nodes, k..<(k + 1))
            let nodes = Array(tree.nodes.prefix(k + 1))
            let got = namespace(&index, nodes, auxiliary: auxiliary)
            expectEquivalent(
                got, oracle(index, nodes, auxiliary: auxiliary), nodes: nodes, "after node \(k)",
                sourceLocation: sourceLocation)
        }
        #expect(index.namespaceBuildCount == 1, sourceLocation: sourceLocation)
    }

    @Test func lateRealReplacesStub() {
        var tree = Tree()
        let system = tree.root("/")
        let data = tree.root("/System/Volumes/Data")
        tree.add(system, "Users", issue: .volumeBoundary)
        tree.add(system, "usr")
        let users = tree.add(data, "Users")
        tree.add(users, "a", .file, bytes: 4096)
        tree.add(users, "b", .file, bytes: 8192)
        compareEveryStep(tree)
        var index = ProgressiveIndex()
        admit(&index, tree.nodes, 0..<tree.nodes.count)
        let ns = namespace(&index, tree.nodes)
        #expect(ns.logicalID(2) == users && ns.topLevel.contains(users) && !ns.topLevel.contains(2))
    }

    @Test func twoRealFilesWithOneNameStayVisibleAndStubsHide() {
        var tree = Tree()
        let system = tree.root("/")
        let data = tree.root("/System/Volumes/Data")
        tree.add(system, "dup.txt", .file, bytes: 4096)
        tree.add(system, "mix")
        tree.add(system, "ghost", issue: .volumeBoundary)
        tree.add(system, "both", issue: .policyExcluded)
        tree.add(data, "dup.txt", .file, bytes: 8192)
        tree.add(data, "mix", .file, bytes: 4096)  // a folder and a file named alike cannot merge
        tree.add(data, "ghost", issue: .volumeBoundary)  // all-stub bucket: the first stands for the rest
        tree.add(data, "both")
        compareEveryStep(tree)
        var index = ProgressiveIndex()
        admit(&index, tree.nodes, 0..<tree.nodes.count)
        let ns = namespace(&index, tree.nodes)
        let names = ns.topLevel.map { tree.nodes[$0].name }
        #expect(names.filter { $0 == "dup.txt" }.count == 2 && names.filter { $0 == "mix" }.count == 2)
        #expect(
            names.filter { $0 == "ghost" }.count == 1
                && ns.hidden[tree.nodes.firstIndex { $0.name == "ghost" && $0.parent == data }!] != nil)
        #expect(names.filter { $0 == "both" }.count == 1)
        // Collisions keep their slot: pages cover every visible entry exactly once.
        var paged: [Int] = []
        var offset = 0
        while let page = ns.page(for: nil, offset: offset, limit: 2), !page.ids.isEmpty {
            paged += page.ids
            offset += page.ids.count
        }
        #expect(paged == ns.list(for: nil)!)
    }

    @Test func nestedMergeAbsorbsStubsInsideMergedFolders() {
        var tree = Tree()
        let system = tree.root("/")
        let data = tree.root("/System/Volumes/Data")
        let s = tree.add(system, "private")
        let d = tree.add(data, "private")
        let sv = tree.add(s, "var", issue: .volumeBoundary)
        let ss = tree.add(s, "spool")
        let dv = tree.add(d, "var")
        let ds = tree.add(d, "spool")
        tree.add(dv, "log", .file, bytes: 4096)
        tree.add(ss, "s.bin", .file, bytes: 4096)
        tree.add(ds, "d.bin", .file, bytes: 4096)
        _ = sv
        compareEveryStep(tree)
    }

    @Test func auxiliaryRootsJoinTheManagedGroupWithoutRebuilding() {
        var tree = Tree()
        let system = tree.root("/")
        tree.root("/System/Volumes/Data")
        tree.add(system, "System")
        tree.add(system, "Users")
        let aux = tree.root("/Volumes/Aux")
        tree.add(aux, "x.bin", .file, bytes: 4096)
        compareEveryStep(tree, auxiliary: ["/Volumes/Aux"], from: 4)
    }

    /// Flipping a stub to a real folder after it was admitted changes the group's primary to a lower id.
    @Test func lateLowerPrimaryRemapsHiddenMembersAndParents() {
        var tree = Tree()
        let system = tree.root("/")
        let data = tree.root("/System/Volumes/Data")
        let stub = tree.add(system, "Users", issue: .volumeBoundary)
        let real = tree.add(data, "Users")
        tree.add(real, "alice", .directory)
        tree.add(real, "bob", .file, bytes: 4096)
        var index = ProgressiveIndex.counted()
        admit(&index, tree.nodes, 0..<tree.nodes.count)
        var before = namespace(&index, tree.nodes)
        #expect(before.topLevel == [real] && before.hidden == [stub: real] && before.members.isEmpty)

        tree.nodes[stub].issue = nil  // the System side turns out to be a real folder
        index.entryChanged(stub)
        let child = tree.add(stub, "carol", .file, bytes: 8192)
        admit(&index, tree.nodes, child..<(child + 1))
        let after = namespace(&index, tree.nodes)
        before = oracle(index, tree.nodes)
        expectEquivalent(after, before, nodes: tree.nodes, "after flip")
        #expect(after.topLevel == [stub] && after.hidden == [real: stub] && after.members[stub] == [stub, real])
        #expect(after.logicalID(real) == stub && after.parent(of: real, nodes: tree.nodes) == nil)
        #expect(
            Set(after.list(for: stub) ?? [])
                == Set([
                    tree.nodes.firstIndex { $0.name == "alice" }!, tree.nodes.firstIndex { $0.name == "bob" }!, child,
                ]))
        #expect(index.namespaceBuildCount == 1)
    }

    @Test func primaryChangeInsideAMergedFolderRebuildsOnlyThatFolder() {
        // Three same-named entries: the System stub plus two real Data folders (a fixture-only shape that exercises teardown).
        var tree = Tree()
        let system = tree.root("/")
        let data = tree.root("/System/Volumes/Data")
        let stub = tree.add(system, "Shared", issue: .volumeBoundary)
        tree.add(system, "Other")
        let a = tree.add(data, "Shared")
        let b = tree.add(data, "Shared")
        let aSub = tree.add(a, "Deep")
        let bSub = tree.add(b, "Deep")
        tree.add(aSub, "f1", .file, bytes: 4096)
        tree.add(bSub, "f2", .file, bytes: 4096)
        var index = ProgressiveIndex.counted()
        admit(&index, tree.nodes, 0..<tree.nodes.count)
        let first = namespace(&index, tree.nodes)
        #expect(first.members[a] == [a, b])
        expectEquivalent(first, oracle(index, tree.nodes), nodes: tree.nodes, "before")
        tree.nodes[stub].issue = nil
        index.entryChanged(stub)
        let second = namespace(&index, tree.nodes)
        expectEquivalent(second, oracle(index, tree.nodes), nodes: tree.nodes, "after")
        #expect(second.members[a] == nil && second.members[stub] == [stub, a, b])
        #expect(index.namespaceBuildCount == 1)
    }

    // MARK: Cancellation

    private func environment(_ nodes: [ScanNode], _ ranges: [Int: Range<Int>], cancelAt: Int?, polls: PollCounter)
        -> NamespaceBuilder.Environment
    {
        NamespaceBuilder.Environment(
            nodes: nodes,
            cancelled: {
                polls.value += 1
                return cancelAt.map { polls.value >= $0 } ?? false
            },
            bytes: { _ in (0, 0) },
            children: { parent, limit in
                guard let range = ranges[parent] else { return [] }
                let upper = min(range.upperBound, limit)
                return range.lowerBound < upper ? Array(range.lowerBound..<upper) : []
            })
    }

    /// System side first (so every Data twin is a late merge), with a stub twin, files and nested merged folders.
    private func lateTwinTree(top: Int, subs: Int, files: Int) -> (tree: Tree, firstSystemTop: Int, phaseOne: Int) {
        var tree = Tree()
        let system = tree.root("/")
        let data = tree.root("/System/Volumes/Data")
        func side(_ root: Int, stub: Bool) {
            var tops = (0..<top).map { tree.add(root, "dir\($0)") }
            tops.append(tree.add(root, "Users", issue: stub ? .volumeBoundary : nil))
            var subIDs: [Int] = []
            for id in tops { for s in 0..<subs { subIDs.append(tree.add(id, "sub\(s)")) } }
            for id in subIDs {
                for f in 0..<files { tree.add(id, "f\(f).bin", .file, bytes: UInt64(4096 * (1 + (id + f) % 5))) }
            }
        }
        side(system, stub: true)
        let phaseOne = tree.nodes.count
        side(data, stub: false)
        return (tree, 2, phaseOne)
    }

    @Test func cancellationAtEveryPollLeavesACoherentResumableBuilder() {
        let tree = lateTwinTree(top: 3, subs: 2, files: 2).tree
        var index = ProgressiveIndex()
        admit(&index, tree.nodes, 0..<tree.nodes.count)
        let nodes = tree.nodes
        let rootPaths = [0: "/", 1: "/System/Volumes/Data"]
        let expected = oracle(index, nodes)

        let counted = PollCounter()
        var clean = NamespaceBuilder()
        #expect(
            clean.advance(environment(nodes, index.ranges, cancelAt: nil, polls: counted), rootPaths: rootPaths)
                == .done)
        expectEquivalent(clean.view, expected, nodes: nodes, "uncancelled")
        let totalPolls = counted.value
        #expect(totalPolls > nodes.count)

        for cancelAt in 1...totalPolls {
            let work = IndexWorkCounter()
            var builder = NamespaceBuilder(observer: work)
            let polls = PollCounter()
            let outcome = builder.advance(
                environment(nodes, index.ranges, cancelAt: cancelAt, polls: polls), rootPaths: rootPaths)
            // Bounded: no admission happens after the poll that reports cancellation.
            #expect(outcome == .cancelled && work.current.namespaceVisits <= cancelAt, "poll \(cancelAt)")
            #expect(polls.value == cancelAt, "no polling after cancellation, poll \(cancelAt)")
            // Resumable and coherent: finishing the same builder gives exactly the full-build result.
            let resumed = builder.advance(
                environment(nodes, index.ranges, cancelAt: nil, polls: PollCounter()), rootPaths: rootPaths)
            #expect(resumed == .done, "poll \(cancelAt)")
            if resumed == .done {
                expectEquivalent(builder.view, expected, nodes: nodes, "resumed after poll \(cancelAt)")
            }
        }
    }

    /// Several entries change after admission (stubs turn out to be real folders); a cancelled step must keep every
    /// group it did not get to, not only the one that was being evaluated when the cancel arrived.
    @Test func cancellationMidBatchKeepsEveryUnprocessedChangedGroup() {
        let rootPaths = [0: "/", 1: "/System/Volumes/Data"]
        var tree = Tree()
        let system = tree.root("/")
        let data = tree.root("/System/Volumes/Data")
        let names = ["alpha", "beta", "gamma", "delta"]
        // Children of one directory stay contiguous, as the scanner appends them.
        let stubs = names.map { tree.add(system, $0, issue: .volumeBoundary) }
        for folder in names.map({ tree.add(data, $0) }) { tree.add(folder, "f.bin", .file, bytes: 4096) }
        var index = ProgressiveIndex()
        admit(&index, tree.nodes, 0..<tree.nodes.count)
        var flipped = tree.nodes
        for stub in stubs { flipped[stub].issue = nil }

        var expected = NamespaceBuilder()
        _ = expected.advance(
            environment(tree.nodes, index.ranges, cancelAt: nil, polls: PollCounter()), rootPaths: rootPaths)
        for stub in stubs { expected.entryChanged(stub) }
        #expect(
            expected.advance(
                environment(flipped, index.ranges, cancelAt: nil, polls: PollCounter()), rootPaths: rootPaths) == .done)
        #expect(
            stubs.allSatisfy { expected.view.members[$0]?.count == 2 },
            "fixture: every flipped stub becomes a merged folder")

        // Count the polls the changed-entry phase needs, then cancel at each one of them in turn.
        func settledBuilder() -> NamespaceBuilder {
            var builder = NamespaceBuilder()
            _ = builder.advance(
                environment(tree.nodes, index.ranges, cancelAt: nil, polls: PollCounter()), rootPaths: rootPaths)
            for stub in stubs { builder.entryChanged(stub) }
            return builder
        }
        let counted = PollCounter()
        var uncancelled = settledBuilder()
        #expect(
            uncancelled.advance(environment(flipped, index.ranges, cancelAt: nil, polls: counted), rootPaths: rootPaths)
                == .done)
        #expect(counted.value >= stubs.count)

        for cancelAt in 1...counted.value {
            var builder = settledBuilder()
            let outcome = builder.advance(
                environment(flipped, index.ranges, cancelAt: cancelAt, polls: PollCounter()), rootPaths: rootPaths)
            #expect(outcome == .cancelled, "poll \(cancelAt)")
            let resumed = builder.advance(
                environment(flipped, index.ranges, cancelAt: nil, polls: PollCounter()), rootPaths: rootPaths)
            #expect(resumed == .done, "poll \(cancelAt)")
            expectEquivalent(builder.view, expected.view, nodes: flipped, "resumed after poll \(cancelAt)")
        }
    }

    @Test func cancelledSnapshotUsesIdentityButKeepsTheValidCache() async {
        let fixture = lateTwinTree(top: 4, subs: 3, files: 2)
        let tree = fixture.tree
        var index = ProgressiveIndex.counted()
        admit(&index, tree.nodes, 0..<fixture.phaseOne)
        _ = namespace(&index, Array(tree.nodes.prefix(fixture.phaseOne)))
        admit(&index, tree.nodes, fixture.phaseOne..<tree.nodes.count)
        let nodes = tree.nodes
        let target = fixture.firstSystemTop  // late Data twins register the System side first
        let result = await Task.detached { [index] () -> (LogicalNamespace, ProgressiveIndex) in
            var local = index
            local.namespaceChildren = { parent in if parent == target { withUnsafeCurrentTask { $0?.cancel() } } }
            let value = local.logicalNamespace(nodes: nodes, urls: [systemURL, dataURL], coverage: wholeDrive)
            return (value, local)
        }.value
        #expect(!result.0.unified && result.0.members.isEmpty && result.0.hidden.isEmpty)
        var resumed = result.1
        resumed.namespaceChildren = nil
        #expect(resumed.namespaceBuildCount == 1, "cancellation keeps the cache; it is never replaced or rebuilt")
        let finished = resumed.logicalNamespace(nodes: nodes, urls: [systemURL, dataURL], coverage: wholeDrive)
        expectEquivalent(finished, oracle(resumed, nodes), nodes: nodes, "resumed")
        #expect(resumed.namespaceBuildCount == 1)
    }

    // MARK: Ordered slots

    @Test func slotListPagesMatchTheFlattenedOrderAfterEveryMutation() {
        var list = SlotList()
        var model: [[Int]] = []
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        var nextID = 0
        for step in 0..<400 {
            if model.isEmpty || next(3) != 0 {
                list.append(nextID)
                model.append([nextID])
                nextID += 1
            } else {
                let slot = next(model.count)
                let size = 1 + next(4)
                let ids = (0..<size).map { _ in
                    defer { nextID += 1 }
                    return nextID
                }
                list.set(slot: slot, ids)
                model[slot] = ids
            }
            guard step % 20 == 0 else { continue }
            let flat = model.flatMap { $0 }
            #expect(list.all == flat && list.count == flat.count)
            for offset in stride(from: 0, through: flat.count + 1, by: 7) {
                for limit in [0, 1, 5, 64] {
                    #expect(list.page(offset: offset, limit: limit) == Array(flat.dropFirst(offset).prefix(limit)))
                }
            }
        }
    }
}
