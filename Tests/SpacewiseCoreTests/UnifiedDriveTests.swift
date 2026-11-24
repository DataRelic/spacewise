import Foundation
import SpacewiseFixtures
import Testing

@testable import SpacewiseCore

// Unified startup-drive presentation: one namespace rooted at /, collision-aware System/Data merging, a single
// inspectable system-managed group, exact area accounting, node identity, and live/settled parity.

private let drive = PresentationFixtures.wholeDrive()
private let group = LogicalNamespace.managedGroupID

private func names(_ ids: some Sequence<Int>, in result: ScanResult) -> [String] {
    ids.compactMap { result.logicalNode(for: $0)?.name }
}
private func id(_ path: [String], in result: ScanResult = drive, from scope: Int? = nil) -> Int? {
    var cursor = scope
    for part in path {
        guard let next = result.logicalChildIDs(of: cursor).first(where: { result.logicalNode(for: $0)?.name == part })
        else { return nil }
        cursor = next
    }
    return cursor
}

@Test func scannerPassesWholeDriveCoverageIntoTheResult() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    try Data(repeating: 1, count: 20_000).write(to: root.appendingPathComponent("entry"))
    let observed = try #require(DriveDiscovery.mountedIdentity(root.path))
    let evidence = DiscoveredRoot(
        url: root, fsid: observed.0, device: String(observed.1.dropFirst(5)), uuid: UUID(), disk: "fixture")
    let discovery = DriveDiscovery(evidence: [evidence], roots: [root], unresolved: [])
    let result = await Scanner.scan(
        plan: ScanPlan(roots: [root], startup: true), injectedDiscovery: { discovery }, injectedFailure: nil,
        update: { _ in })
    // Whole-drive coverage must be set during result construction so auxiliary roots count as system-managed.
    #expect(result.coverage.wholeDrive)
    #expect((result.measuredCategories()[.systemManaged]?.allocatedBytes ?? 0) > 0)
}

@Test func unifiedRootHasNoImplementationVolumesOrDuplicateRows() throws {
    #expect(drive.namespace.unified)
    let top = names(drive.logicalChildIDs(of: nil), in: drive)
    #expect(!top.contains("/") && !top.contains("/System/Volumes/Data"))
    #expect(Set(top).count == top.count)  // never two rows with one name
    #expect(top.contains("Users") && top.contains("Applications") && top.contains("Library"))
    #expect(top.contains(LogicalNamespace.managedGroupName))
    // System, usr, private and bin are classified system-managed: inside the group, not beside it.
    for managedName in ["System", "usr", "private", "bin"] { #expect(!top.contains(managedName)) }
    let inside = names(drive.logicalChildIDs(of: group), in: drive)
    for managedName in ["System", "usr", "private", "bin", "VM volume", "Preboot volume"] {
        #expect(inside.contains(managedName), "\(managedName) missing from the group")
    }
}

@Test func mergedFoldersKeepIdentityPhysicalPathsAndSumMembers() throws {
    let system = try #require(id([LogicalNamespace.managedGroupName, "System"]))
    let members = drive.namespace.physicalMembers(of: system)
    #expect(members.count == 2)
    // The logical id is the lower physical id: identity is preserved, never re-minted.
    #expect(system == members.min())
    #expect(members.allSatisfy { drive.node(for: $0)?.name == "System" })
    let sum = members.reduce(UInt64(0)) { $0 + drive.nodes[$1].allocatedBytes }
    #expect(drive.logicalNode(for: system)?.allocatedBytes == sum)
    let paths = drive.physicalPaths(for: system)
    #expect(Set(paths) == ["/System", "/System/Volumes/Data/System"])
    #expect(drive.logicalPathString(for: system) == "/System")
    #expect(drive.trashTarget(for: system) == nil)
    // The Data side resolves back to the same logical node and is not a second row.
    let hiddenMember = try #require(members.first { $0 != system })
    #expect(drive.namespace.logicalID(hiddenMember) == system)
    #expect(!drive.logicalChildIDs(of: group).contains(hiddenMember))
    // Merging recurses: /System/Library exists on both volumes and is one logical folder with both sides' items.
    let library = try #require(id(["System", "Library"], from: group))
    #expect(drive.namespace.isMerged(library))
    let inside = names(drive.logicalChildIDs(of: library), in: drive)
    #expect(inside.contains("Frameworks") && inside.contains("AssetsV2") && inside.contains("dyld-shared-cache"))
    #expect(Set(inside).count == inside.count)
}

@Test func firmLinkStubsAreAbsorbedNotShown() throws {
    let users = try #require(id(["Users"]))
    #expect(!drive.namespace.isMerged(users))
    let stubs = drive.nodes.filter { $0.name == "Users" && $0.issue == .volumeBoundary }
    #expect(stubs.count == 1)
    #expect(drive.namespace.logicalID(stubs[0].id) == users)  // the stub stands for the real folder
    #expect(drive.logicalNode(for: users)?.allocatedBytes == drive.nodes[users].allocatedBytes)
    // /private/var is a stub on the System side and real on Data: one row, with the Data content.
    let variable = try #require(id(["private", "var"], from: group))
    #expect(drive.nodes[variable].issue == nil)
    #expect(drive.nodes[variable].allocatedBytes > 0)
}

@Test func areaAndTotalsReconcileWithoutDoubleCounting() throws {
    let total = drive.logicalSummary(parent: nil).allocatedBytes
    #expect(total == drive.progress.allocatedBytes)
    #expect(total == drive.nodes.filter { $0.parent == nil }.reduce(0) { $0 + $1.allocatedBytes })
    let row = try #require(drive.logicalRow(for: group))
    #expect(drive.trashTarget(for: group) == nil)
    let categories = drive.measuredCategories()
    // The group's measured total is the cached attributed system-managed category, not a capacity difference.
    #expect(row.node.allocatedBytes == categories[.systemManaged]?.allocatedBytes)
    #expect(row.node.logicalBytes == categories[.systemManaged]?.logicalBytes)
    let others = ContentClassification.allCases.filter { $0 != .systemManaged }.reduce(UInt64(0)) {
        $0 + (categories[$1]?.allocatedBytes ?? 0)
    }
    #expect(row.node.allocatedBytes + others == total)
    // Unknown stays unknown: the group reports partial coverage and the totals do not grow to fill it.
    #expect(
        row.node.allocationUnknown && row.coverage == .partial && row.classification == .systemManaged
            && row.eligibility == .inspectionOnly)
    let model = drive.logicalTreemap(parent: nil)
    #expect(model.rootWeight == total)
    let groupTile = try #require(model.tileIndex(forNode: group))
    #expect(model.tiles[groupTile].weight == row.node.allocatedBytes)
}

@Test func managedGroupHoldsRealDescendantTilesOnly() throws {
    let model = drive.logicalTreemap(parent: nil)
    let groupTile = try #require(model.tileIndex(forNode: group))
    #expect(model.tiles[groupTile].managed && model.tiles[groupTile].parent == 0)
    var inside = Set<Int>()
    var stack = [groupTile]
    while let tile = stack.popLast() {
        inside.insert(tile)
        stack += Array(model.tiles[tile].children)
    }
    #expect(inside.count > 20)
    for (index, tile) in model.tiles.enumerated() where index > 0 {
        #expect(tile.managed == inside.contains(index), "tile \(index) managed flag disagrees with its position")
    }
    // Real nodes, never category copies: every drawn node appears once and none is a root volume.
    let drawn = model.tiles.compactMap { $0.nodeID >= 0 ? $0.nodeID : nil }
    #expect(Set(drawn).count == drawn.count)
    #expect(!drawn.contains(drive.namespace.systemRoot!) && !drawn.contains(drive.namespace.dataRoot!))
    // Exact accounting at every level.
    for tile in model.tiles where tile.childCount > 0 {
        #expect(tile.children.reduce(UInt64(0)) { $0 + model.tiles[$1].weight } == tile.weight)
    }
    // The legend adds up: type rows exclude managed leaves, which have exactly one row of their own.
    let legend = model.legend()
    #expect(legend.reduce(UInt64(0)) { $0 + $1.weight } == model.rootWeight)
    #expect(legend.filter { $0.category == .managedZone }.count == 1)
    #expect(legend.first { $0.category == .managedZone }?.weight == model.tiles[groupTile].weight)
}

@Test func denialsAndUnknownCarryNoArea() throws {
    let model = drive.logicalTreemap(parent: nil)
    let denied = drive.nodes.filter { $0.issue == .denied }.map(\.id)
    #expect(denied.count == 2)
    for node in denied { #expect(model.tileIndex(forNode: node) == nil) }
    let stubs = drive.nodes.filter { $0.issue == .volumeBoundary }.map(\.id)
    for node in stubs { #expect(model.tileIndex(forNode: node) == nil) }
    #expect(drive.logicalSummary(parent: nil).allocationUnknown)
}

@Test func logicalParentsAndTileParentsAgreeEverywhere() throws {
    for scope in [nil, group, id(["Users"]), id([LogicalNamespace.managedGroupName, "System"])] as [Int?] {
        let model = drive.logicalTreemap(parent: scope)
        #expect(
            model.rootWeight
                == (scope.flatMap { drive.logicalNode(for: $0)?.allocatedBytes } ?? drive.progress.allocatedBytes))
        for (index, tile) in model.tiles.enumerated() where index > 0 && tile.nodeID >= 0 {
            let parentTile = model.tiles[tile.parent]
            let expected = parentTile.nodeID >= 0 && tile.parent != 0 ? parentTile.nodeID : scope
            #expect(
                drive.logicalParent(of: tile.nodeID) == expected,
                "logical parent of \(drive.logicalNode(for: tile.nodeID)?.name ?? "?") differs from its tile parent")
        }
    }
}

@Test func linkedSelectionResolvesThroughMergedAncestors() throws {
    let model = drive.logicalTreemap(parent: nil)
    let target = try #require(drive.nodes.first { $0.name == "dyld-shared-cache" }?.id)
    let tile = try #require(model.tileIndex(forNode: target))
    // The list row for a deep tile is the top-level logical entry: the managed group.
    #expect(model.scopeLevelNode(of: tile) == group)
    #expect(model.nearestTile(forNode: target, parentOf: { drive.logicalParent(of: $0) }) == tile)
    // A node on the Data side of a merged folder still reaches the group through its logical ancestors.
    let asset = try #require(drive.nodes.first { $0.name.hasPrefix("asset-") }?.id)
    var cursor: Int? = asset
    var reached = false
    while let current = cursor {
        if current == group { reached = true }
        cursor = drive.logicalParent(of: current)
    }
    #expect(reached)
    #expect(drive.logicalChildIDs(of: nil).contains(group))
}

@Test func folderScansAreUntouched() {
    let folder = PresentationFixtures.storageMap(tailFiles: 400)
    #expect(!folder.namespace.unified)
    #expect(Array(folder.logicalChildIDs(of: 0)) == Array(folder.childIDs(of: 0)))
    #expect(folder.logicalRow(for: 1)?.node.id == folder.scopeRow(for: 1)?.node.id)
    #expect(folder.logicalTreemap(parent: 0).tiles.count == folder.treemap(parent: 0).tiles.count)
    #expect(folder.logicalTreemap(parent: 0).tiles.allSatisfy { !$0.managed })
}

@Test func liveSnapshotsPresentTheSameUnifiedNamespace() throws {
    var index = ProgressiveIndex()
    for node in drive.nodes { index.append(node) }
    for node in drive.nodes {
        index.attribute(logical: node.logicalBytes, allocated: node.allocatedBytes, to: node.parent, nodes: drive.nodes)
    }
    let urls = drive.roots
    var progress = drive.progress
    progress.state = .limited
    func snapshot(_ parent: Int?, treemap: Bool = false) -> ScopeSnapshot {
        index.snapshot(
            scanID: UUID(), revision: 1, request: ScopeRequest(parent: parent), nodes: drive.nodes, urls: urls,
            coverage: drive.coverage, progress: progress, includeTreemap: treemap)
    }
    for scope in [nil, group, id(["Users"]), id([LogicalNamespace.managedGroupName, "System"])] as [Int?] {
        let live = snapshot(scope, treemap: true)
        #expect(
            Set(live.rows.map(\.node.id)) == Set(drive.logicalChildIDs(of: scope)), "scope \(String(describing: scope))"
        )
        #expect(live.scope.crumbs.map(\.id) == drive.logicalSummary(parent: scope).crumbs.map(\.id))
        #expect(live.scope.allocatedBytes == drive.logicalSummary(parent: scope).allocatedBytes)
        #expect(live.treemap?.rootWeight == drive.logicalTreemap(parent: scope).rootWeight)
        #expect(live.parentOfScope == scope.flatMap { drive.logicalParent(of: $0) })
    }
    // While scanning, the group is partial (unknown), provisional, and never claims more than was found.
    var scanning = progress
    scanning.state = .scanning
    let live = index.snapshot(
        scanID: UUID(), revision: 2, request: ScopeRequest(parent: nil), nodes: drive.nodes, urls: urls,
        coverage: drive.coverage, progress: scanning)
    let row = try #require(live.rows.first { $0.node.id == group })
    #expect(row.coverage == .partial && live.provisional && live.scope.allocationUnknown)
}

@Test func unchangedNamespaceCheckpointsReuseTopology() {
    var index = ProgressiveIndex.counted()
    for node in drive.nodes { index.append(node) }
    let first = index.logicalNamespace(nodes: drive.nodes, urls: drive.roots, coverage: drive.coverage)
    let builds = index.namespaceBuildCount
    let work = index.namespaceBuildNodeCount
    for _ in 0..<10 {
        let next = index.logicalNamespace(nodes: drive.nodes, urls: drive.roots, coverage: drive.coverage)
        #expect(next.list(for: nil) == first.list(for: nil))
    }
    #expect(index.namespaceBuildCount == builds)
    #expect(index.namespaceBuildNodeCount == work)
    index.invalidateNamespace()
    _ = index.logicalNamespace(nodes: drive.nodes, urls: drive.roots, coverage: drive.coverage)
    #expect(index.namespaceBuildCount == builds + 1)
}

@Test func namespacePagesPreserveDiscoveryOrderAndGroupBoundary() throws {
    let ns = drive.namespace
    let all = try #require(ns.list(for: nil))
    for offset in 0...(all.count + 1) {
        let page = try #require(ns.page(for: nil, offset: offset, limit: 2))
        #expect(page.total == all.count)
        #expect(page.ids == Array(all.dropFirst(offset).prefix(2)))
    }
    #expect(ns.page(for: nil, offset: 0, limit: 0)?.ids.isEmpty == true)
}

@Test func physicalRootSummaryMatchesUnifiedWholeDriveInEveryState() {
    var index = ProgressiveIndex()
    for node in drive.nodes { index.append(node) }
    for root in index.roots { index.totals[root] = (drive.nodes[root].logicalBytes, drive.nodes[root].allocatedBytes) }
    for state in [ScanState.scanning, .cancelled, .completed] {
        var progress = drive.progress
        progress.state = state
        let base = ProvisionalTreemapSource(
            index: index, nodes: drive.nodes, urls: drive.roots, coverage: drive.coverage, progress: progress)
        let expected = drive.namespace.summary(
            parent: nil, nodes: drive.nodes, base: base.row(for:), scanning: state == .scanning,
            issue: { drive.nodes[$0].issue }, enumeration: { drive.coverage.enumeration[$0] })
        let actual = index.snapshot(
            scanID: UUID(), revision: 1, request: ScopeRequest(), nodes: drive.nodes,
            urls: drive.roots, coverage: drive.coverage, progress: progress
        ).scope
        #expect(actual.logicalBytes == expected.logicalBytes)
        #expect(actual.allocatedBytes == expected.allocatedBytes)
        #expect(actual.allocationUnknown == expected.allocationUnknown)
        #expect(actual.crumbs.isEmpty)
    }
}

@Test func managedAggregateQueriesNeverReadMembers() {
    var nodes = [ScanNode(id: 0, parent: nil, name: "/", kind: .directory, device: 0, inode: 0)]
    for id in 1...4000 {
        var node = ScanNode(id: id, parent: 0, name: ".managed-\(id)", kind: .file, device: 0, inode: UInt64(id))
        node.logicalBytes = 7
        node.allocatedBytes = 9
        nodes.append(node)
    }
    var namespace = LogicalNamespace.build(nodes: nodes, rootPaths: [0: "/"], wholeDrive: true, isCancelled: { false })
    { id in id == 0 ? Array(1...4000) : [] }
    namespace.managedAggregate.logicalBytes = 28000
    namespace.managedAggregate.allocatedBytes = 36000
    var reads = 0
    for _ in 0..<1000 {
        let row = namespace.row(for: LogicalNamespace.managedGroupID, nodes: nodes) { _ in
            reads += 1
            return nil
        }
        #expect(row?.node.allocatedBytes == 36000)
        #expect(row?.node.logicalBytes == 28000)
    }
    #expect(reads == 0)
}
