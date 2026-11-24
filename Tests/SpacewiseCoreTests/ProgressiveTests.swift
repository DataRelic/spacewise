import Foundation
import SpacewiseFixtures
import Synchronization
import Testing

@testable import SpacewiseCore

@Test func boundedPagesAndObsoleteSnapshotRejection() {
    let fixture = PresentationFixtures.scenario(.complete)
    var index = ProgressiveIndex()
    for node in fixture.result.nodes { index.append(node) }
    let request = ScopeRequest(parent: 0, offset: 256, generation: 9)
    let page = index.snapshot(
        scanID: fixture.result.id, revision: 4, request: request,
        nodes: fixture.result.nodes, urls: fixture.result.roots,
        coverage: fixture.result.coverage, progress: fixture.result.progress)
    #expect(fixture.snapshot.rows.count == ScopeSnapshot.pageSize)
    #expect(page.rows.count == page.discoveredChildren - ScopeSnapshot.pageSize)
    #expect(Set(page.rows.map { $0.node.id }).isDisjoint(with: fixture.snapshot.rows.map { $0.node.id }))
    #expect(page.isCurrent(scanID: fixture.result.id, request: request, after: 3))
    #expect(page.isCurrent(scanID: UUID(), request: request, after: 3) == false)
    #expect(
        page.isCurrent(scanID: fixture.result.id, request: ScopeRequest(parent: 0, generation: 10), after: 3) == false)
    #expect(page.isCurrent(scanID: fixture.result.id, request: request, after: 4) == false)
    let beyond = index.snapshot(
        scanID: fixture.result.id, revision: 5, request: ScopeRequest(parent: -1, offset: Int.max),
        nodes: fixture.result.nodes, urls: fixture.result.roots,
        coverage: fixture.result.coverage, progress: fixture.result.progress)
    #expect(beyond.rows.isEmpty)
}

@Test func provisionalOwnerTransferRemovesOldAncestorTotals() {
    var nodes = [
        ScanNode(id: 0, parent: nil, name: "root", kind: .directory, device: 1, inode: 0),
        ScanNode(id: 1, parent: 0, name: "z", kind: .directory, device: 1, inode: 1),
        ScanNode(id: 2, parent: 0, name: "a", kind: .directory, device: 1, inode: 2),
        ScanNode(
            id: 3, parent: 1, name: "file", kind: .file, logicalBytes: 17, allocatedBytes: 4096, device: 1, inode: 3),
    ]
    var index = ProgressiveIndex()
    index.attribute(logical: 17, allocated: 4096, to: 1, nodes: nodes)
    #expect(index.totals[1]?.logical == 17)
    index.attribute(logical: 17, allocated: 4096, to: 1, nodes: nodes, subtract: true)
    index.attribute(logical: 17, allocated: 4096, to: 2, nodes: nodes)
    nodes[3].logicalBytes = 0
    nodes[3].allocatedBytes = 0
    nodes.append(
        ScanNode(
            id: 4, parent: 2, name: "file", kind: .file, logicalBytes: 17, allocatedBytes: 4096, device: 1, inode: 3))
    Scanner.finalizeCoverage(nodes: &nodes, coverage: LocationCoverage())
    for id in 0...2 {
        #expect(index.totals[id]?.logical == nodes[id].logicalBytes)
        #expect(index.totals[id]?.allocated == nodes[id].allocatedBytes)
    }
}

@Test func scannerSnapshotsSettleWithSameIdentityAndBoundedRows() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    for i in 0..<300 { try Data([1]).write(to: fixture.root.appending(path: "file-\(i)")) }
    let scanID = UUID()
    let snapshots = Mutex<[ScopeSnapshot]>([])
    let request = Mutex(ScopeRequest(parent: 0))
    let result = await Scanner.scan(
        plan: ScanPlan(folder: fixture.root), scanID: scanID,
        scopeRequest: { request.withLock { $0 } },
        scopeUpdate: { snapshot in
            snapshots.withLock { $0.append(snapshot) }
            if snapshot.revision == 1 {
                // Multiple navigation changes collapse to the latest value before the next checkpoint.
                request.withLock { $0 = ScopeRequest(parent: nil, generation: 1) }
                request.withLock { $0 = ScopeRequest(parent: 0, generation: 2) }
            }
        }
    ) { _ in }
    let values = snapshots.withLock { $0 }
    #expect(values.count >= 2)
    #expect(values.allSatisfy { $0.scanID == result.id && $0.rows.count <= 256 })
    #expect(values.first?.provisional == true)
    #expect(values.last?.provisional == false)
    #expect(result.progress.state == .completed)
    #expect(result.progress.issues.isEmpty)
    #expect(result.nodes.first?.allocationUnknown == false)
    #expect(values.last?.rows.count == ScopeSnapshot.pageSize)
    #expect(values.last?.discoveredChildren == 300)
    #expect(values.last?.request.generation == 2)
    #expect(values.contains { $0.request.generation == 1 } == false)
    #expect(values.last?.progress.logicalBytes == result.nodes[0].logicalBytes)
}

@Test func cancellationRetainsBoundedScopeAndUnknownPendingDirectory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let snapshots = Mutex<[ScopeSnapshot]>([])
    let worker = Task {
        await Scanner.scan(
            plan: ScanPlan(folder: fixture.root), scopeRequest: { ScopeRequest() },
            scopeUpdate: { snapshot in
                snapshots.withLock { $0.append(snapshot) }
                if snapshot.provisional { withUnsafeCurrentTask { $0?.cancel() } }
            }
        ) { _ in }
    }
    let result = await worker.value
    #expect(result.progress.state == .cancelled)
    #expect(result.nodes.first?.allocationUnknown == true)
    let final = try #require(snapshots.withLock { $0.last })
    #expect(final.progress.state == .cancelled)
    #expect(final.provisional == false)
    #expect(final.rows.first?.node.allocationUnknown == true)
}

@Test func cachedFlatRootSummaryVisitsOnlyPhysicalRootsAndReadsLateTotals() {
    var nodes = [ScanNode(id: 0, parent: nil, name: "/", kind: .directory, device: 1, inode: 1)]
    var index = ProgressiveIndex.counted()
    index.append(nodes[0])
    for id in 1...100_000 {
        let node = ScanNode(id: id, parent: 0, name: "entry\(id)", kind: .file, device: 1, inode: UInt64(id + 1))
        nodes.append(node)
        index.append(node)
    }
    let coverage = LocationCoverage(wholeDrive: true)
    for revision in 1...3 {
        index.totals[0] = (UInt64(revision), UInt64(revision * 4096))
        let page = index.snapshot(
            scanID: UUID(), revision: UInt64(revision), request: ScopeRequest(), nodes: nodes,
            urls: [URL(fileURLWithPath: "/")], coverage: coverage, progress: ScanProgress())
        #expect(page.scope.logicalBytes == UInt64(revision))
        #expect(page.scope.allocatedBytes == UInt64(revision * 4096))
        #expect(page.scope.crumbs.isEmpty && page.scope.allocationUnknown)
        #expect(index.rootSummaryVisitCount == revision)
        #expect(index.namespaceBuildCount == 1)
    }
}

@Test func growingNamespaceAppendWorkIsLinear() {
    _ = checkNamespaceAppendWorkIsLinear(count: 100_000)
}

/// Grows a flat namespace to `count` entries and asserts the work counters. Returns the time the growth took, for the
/// million-entry benchmark to report; no test gates on it.
func checkNamespaceAppendWorkIsLinear(count: Int) -> Duration {
    var nodes = [ScanNode(id: 0, parent: nil, name: "/", kind: .directory, device: 1, inode: 0)]
    var index = ProgressiveIndex.counted()
    index.append(nodes[0])
    let coverage = LocationCoverage(wholeDrive: true)
    let urls = [URL(fileURLWithPath: "/")]
    _ = index.logicalNamespace(nodes: nodes, urls: urls, coverage: coverage)
    let start = ContinuousClock.now
    for id in 1...count {
        let node = ScanNode(id: id, parent: 0, name: "entry\(id)", kind: .directory, device: 1, inode: UInt64(id))
        nodes.append(node)
        index.append(node)
        if id % 10_000 == 0 {
            #expect(index.logicalNamespace(nodes: nodes, urls: urls, coverage: coverage).topLevel.count == id)
        }
    }
    let elapsed = start.duration(to: .now)
    #expect(index.namespaceBuildCount == 1)
    #expect(index.namespaceAppendWorkCount == count)
    #expect(index.namespaceBuildNodeCount == 1)
    let leaf = ScanNode(
        id: nodes.count, parent: 1, name: "leaf", kind: .file, logicalBytes: 17, allocatedBytes: 32, device: 1, inode: 2
    )
    nodes.append(leaf)
    index.append(leaf)
    index.attribute(logical: 17, allocated: 32, to: 1, nodes: nodes)
    let page = index.snapshot(
        scanID: UUID(), revision: 1, request: ScopeRequest(parent: 1), nodes: nodes, urls: urls, coverage: coverage,
        progress: ScanProgress())
    #expect(page.rows.first?.node.id == leaf.id)
    #expect(page.scope.logicalBytes == 17)
    #expect(index.namespaceBuildCount == 1)
    index.invalidateNamespace()
    _ = index.logicalNamespace(nodes: nodes, urls: urls, coverage: coverage)
    #expect(index.namespaceBuildCount == 2)
    let root = ScanNode(id: nodes.count, parent: nil, name: "aux", kind: .directory, device: 2, inode: 0)
    nodes.append(root)
    index.append(root)
    let withAuxiliary = index.logicalNamespace(
        nodes: nodes, urls: urls + [URL(fileURLWithPath: "/aux")], coverage: coverage)
    // A newly admitted root joins the managed group incrementally; it is not a reason to rebuild the tree.
    #expect(index.namespaceBuildCount == 2)
    #expect(
        withAuxiliary.managed.contains(root.id)
            && withAuxiliary.parent(of: root.id, nodes: nodes) == LogicalNamespace.managedGroupID)
    return elapsed
}

@Test func lateTwinAndChangedStubReconcileWithoutRebuild() {
    var nodes = [
        ScanNode(id: 0, parent: nil, name: "/", kind: .directory, device: 1, inode: 0),
        ScanNode(id: 1, parent: nil, name: "Data", kind: .directory, device: 2, inode: 0),
        ScanNode(id: 2, parent: 0, name: "Users", kind: .directory, device: 1, inode: 1),
    ]
    nodes[2].issue = .volumeBoundary
    var index = ProgressiveIndex.counted()
    for node in nodes { index.append(node) }
    let urls = [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/System/Volumes/Data")]
    let coverage = LocationCoverage(wholeDrive: true)
    _ = index.logicalNamespace(nodes: nodes, urls: urls, coverage: coverage)
    let twin = ScanNode(id: 3, parent: 1, name: "Users", kind: .directory, device: 2, inode: 1)
    nodes.append(twin)
    index.append(twin)
    let merged = index.logicalNamespace(nodes: nodes, urls: urls, coverage: coverage)
    #expect(merged.logicalID(2) == 3)
    #expect(index.namespaceBuildCount == 1)
    nodes[2].issue = nil
    index.entryChanged(2)
    let changed = index.logicalNamespace(nodes: nodes, urls: urls, coverage: coverage)
    #expect(changed.physicalMembers(of: 2) == [2, 3])
    #expect(changed.logicalID(3) == 2 && changed.hidden[2] == nil && changed.topLevel == [2])
    #expect(index.namespaceBuildCount == 1)
}

@Test(.timeLimit(.minutes(1))) func terminalSnapshotAndResultAfterMergeCancellation() async throws {
    let nodes =
        [
            ScanNode(id: 0, parent: nil, name: "/", kind: .directory, device: 1, inode: 1),
            ScanNode(id: 1, parent: nil, name: "Data", kind: .directory, device: 2, inode: 2),
            ScanNode(id: 2, parent: 0, name: "Users", kind: .directory, device: 1, inode: 3),
            ScanNode(id: 3, parent: 1, name: "Users", kind: .directory, device: 2, inode: 4),
        ]
        + (4..<304).map {
            ScanNode(
                id: $0, parent: 2, name: "file\($0)", kind: .file, logicalBytes: 17, allocatedBytes: 4096, device: 1,
                inode: UInt64($0 + 1))
        }
    let snapshots = Mutex<[ScopeSnapshot]>([])
    let updates = Mutex<[ScanProgress]>([])
    let gates = Mutex(0)
    let result = await Task.detached {
        await Scanner.scan(
            plan: ScanPlan(
                roots: [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/System/Volumes/Data")], startup: true),
            scopeRequest: { ScopeRequest(parent: 2) },
            scopeUpdate: { value in snapshots.withLock { $0.append(value) } },
            injectedDiscovery: {
                DriveDiscovery(
                    roots: [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/System/Volumes/Data")], unresolved: [])
            },
            injectedNodes: nodes,
            namespaceChildren: { parent in
                if parent == 2 {
                    gates.withLock { $0 += 1 }
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }, injectedFailure: nil, update: { value in updates.withLock { $0.append(value) } })
    }.value
    let final = try #require(snapshots.withLock { $0.last })
    #expect(gates.withLock { $0 } == 1)
    #expect(snapshots.withLock { $0.count } == 1)
    #expect(updates.withLock { $0.allSatisfy { $0.state == .cancelled } })
    #expect(result.progress.state == .cancelled && final.progress.state == .cancelled)
    #expect(!final.provisional && final.scanID == result.id)
    #expect(Set(final.rows.map(\.node.id)) == [0, 1] && final.discoveredChildren == 2)
    #expect(final.request.parent == nil && final.parentOfScope == nil && final.scope.crumbs.isEmpty)
    #expect(final.enumeration == nil && result.coverage.enumeration[2] == .cancelled)
    #expect(final.scope.logicalBytes == 5100 && final.scope.allocatedBytes == 1_228_800)
    #expect(result.nodes[2].logicalBytes == final.scope.logicalBytes)
    #expect(result.nodes[2].allocatedBytes == final.scope.allocatedBytes)
    #expect(result.nodes[2].allocationUnknown && final.scope.allocationUnknown)
    #expect(
        result.namespace.members.isEmpty && result.namespace.hidden.isEmpty && result.namespace.mergedChildren.isEmpty
            && !result.namespace.unified)
    #expect(result.nodes.map(\.id) == nodes.map(\.id))
    #expect(result.childIDs(of: 2).count == 300)
    for row in final.rows {
        #expect(row.node.parent == nil)
        #expect(row.node.logicalBytes == result.nodes[row.node.id].logicalBytes)
        #expect(row.node.allocatedBytes == result.nodes[row.node.id].allocatedBytes)
    }
}
