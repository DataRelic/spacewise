import Foundation
import Synchronization
import Testing

@testable import SpacewiseCore

// Synthetic scale benchmark of the progressive index and merged namespace. NOT part of the normal suite: it runs only
// when SPACEWISE_BENCH_CELL is set to one of the four cells, one fresh process per cell:
//
//   SPACEWISE_BENCH_CELL=1000000-merged swift test -c release --filter indexScaleBenchmark
//
// Cells: {100000, 1000000} physical entries × {broad (unique top-level names), merged (paired nested System/Data names)}.
// It drives the same core paths the scanner does (ProgressiveIndex append/attribute, checkpoint snapshots with the live
// storage map, settle, repeated managed queries) over deterministic synthetic nodes. No filesystem, no user data. It
// measures core work, never installed-app responsiveness. Generation is outside the timed regions.

private struct BenchFixture {
    var nodes: [ScanNode] = []
    /// New owner → old owner of a transferred hard link (the scanner subtracts the old owner before zeroing it).
    var transfers: [Int: Int] = [:]
    var auxiliary: [String] = []
    /// The probe: a Data-side twin appended last, whose late merge registers `probeSystemTwin`.
    var probeStart = 0
    var probeSystemTwin = 0
    var probeData = 0
}

private func weight(_ salt: Int, _ n: Int) -> UInt64 { UInt64(4096 * (1 + (n &* 7919 &+ salt) % 97)) }

private func makeFixture(entries target: Int, shape: String) -> BenchFixture {
    var tree = Tree()
    let system = tree.root("/")
    let data = tree.root("/System/Volumes/Data")
    var fixture = BenchFixture()
    var auxRoots: [Int] = []
    for k in 0..<8 {
        auxRoots.append(tree.root("/Volumes/Aux\(k)"))
        fixture.auxiliary.append("/Volumes/Aux\(k)")
    }
    let managedNames = ["System", "usr", "private", "bin", "sbin"]
    let links = 16
    var transferred: [Int] = []
    var linkDirs: [Int] = []
    var probes: [Int] = []

    if shape == "broad" {
        // System root: managed folders, link directories, the probe folder, then unique entries.
        var tops = managedNames.map { tree.add(system, $0) }
        for k in 0..<links { linkDirs.append(tree.add(system, "links\(k)")) }
        let probeSystem = tree.add(system, "probe")
        probes.append(probeSystem)
        let fixed = managedNames.count + links + 1 + 2 /* data folders */ + 8 * 200 + links + 5 * 2000 + 16
        let unique = max(1000, target - fixed - 4)
        for i in 0..<unique {
            let unknown = i % 997 == 0
            tree.add(system, "entry\(i)", .file, bytes: unknown ? 0 : weight(1, i), unknown: unknown)
        }
        let dataUsers = tree.add(data, "Users")
        let dataProbe = tree.add(data, "probe")
        probes.append(dataProbe)
        tops += [probeSystem]
        // Files inside managed folders; the first sixteen System files are later transferred.
        for (offset, top) in managedNames.enumerated().map({ ($0.offset, tops[$0.offset]) }) {
            for f in 0..<2000 {
                // One sparse/unknown file in "usr": the managed group must report a lower bound, not a complete total.
                let unknown = offset == 1 && f == 7
                let id = tree.add(top, "m\(f).bin", .file, bytes: unknown ? 0 : weight(offset, f), unknown: unknown)
                if offset == 0, f < links { transferred.append(id) }
            }
        }
        for (k, root) in auxRoots.enumerated() {
            for f in 0..<200 { tree.add(root, "a\(f)", .file, bytes: weight(3, k * 200 + f)) }
        }
        tree.add(dataUsers, "u0", .file, bytes: 8192)
        for (k, dir) in linkDirs.enumerated() {
            let id = tree.add(dir, "link", .file, bytes: tree.nodes[transferred[k]].allocatedBytes)
            fixture.transfers[id] = transferred[k]
        }
    } else {
        // Paired nested folders: every System entry precedes its Data twin, so every merge is late.
        let subs = 8
        let files = 4
        let perSide = 1 + subs * (1 + files)
        let pairs = max(10, (target - 8 * 200 - 2 * links - 4 * 40) / (2 * perSide))
        func side(_ root: Int, isSystem: Bool) -> [Int] {
            var tops: [Int] = []
            for t in 0..<pairs {
                tops.append(
                    tree.add(
                        root, t < managedNames.count ? managedNames[t] : (t == managedNames.count ? "probe" : "dir\(t)")
                    ))
            }
            if isSystem { for k in 0..<links { linkDirs.append(tree.add(root, "links\(k)")) } }
            var subIDs: [(Int, Int)] = []
            // The probe folder stays empty here; the probe's twin folders are appended to it last.
            for (t, top) in tops.enumerated() where t != managedNames.count {
                for s in 0..<subs { subIDs.append((tree.add(top, "sub\(s)"), t)) }
            }
            for (sub, t) in subIDs {
                for f in 0..<files {
                    let unknown = (sub + f) % 997 == 0 || (isSystem && t == 1 && f == 3 && sub == subIDs.first?.0)
                    let id = tree.add(sub, "f\(f).bin", .file, bytes: unknown ? 0 : weight(isSystem ? 5 : 6, sub + f))
                    if isSystem && t < 2 && transferred.count < links && f == 0 { transferred.append(id) }
                }
            }
            return tops
        }
        let systemTops = side(system, isSystem: true)
        _ = side(data, isSystem: false)
        probes = [systemTops[managedNames.count]]
        for (k, root) in auxRoots.enumerated() {
            for f in 0..<200 { tree.add(root, "a\(f)", .file, bytes: weight(3, k * 200 + f)) }
        }
        for (k, dir) in linkDirs.enumerated() {
            let id = tree.add(dir, "link", .file, bytes: tree.nodes[transferred[k]].allocatedBytes)
            fixture.transfers[id] = transferred[k]
        }
        // Data-side probe folder id: the second "probe" node.
        probes = tree.nodes.indices.filter { tree.nodes[$0].name == "probe" }
    }

    // Probe: appended last. System twin first (under its probe folder), then the Data twin, 200 files each.
    fixture.probeStart = tree.nodes.count
    let probeSystem = tree.nodes.indices.filter { tree.nodes[$0].name == "probe" }.first!
    let probeData = tree.nodes.indices.filter { tree.nodes[$0].name == "probe" }.last!
    let twinSystem = tree.add(probeSystem, "twin")
    for f in 0..<200 { tree.add(twinSystem, "p\(f).bin", .file, bytes: weight(7, f)) }
    let twinData = tree.add(probeData, "twin")
    for f in 0..<200 { tree.add(twinData, "q\(f).bin", .file, bytes: weight(8, f)) }
    fixture.probeSystemTwin = twinSystem
    fixture.probeData = twinData
    _ = probes
    fixture.nodes = tree.nodes
    return fixture
}

private final class IndexBox: @unchecked Sendable {
    var index: ProgressiveIndex
    var probeIdentity = false
    init(_ index: ProgressiveIndex) { self.index = index }
}

/// Chosen at compile time: calling `_isDebugAssertConfiguration()` made the compiler flag the other branch as dead.
private let buildConfiguration: String = {
    #if DEBUG
        "debug"
    #else
        "release"
    #endif
}()

private func megabytes(_ value: UInt64?) -> Double { Double(value ?? 0) / 1_048_576 }
private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SPACEWISE_BENCH_CELL"] != nil))
func indexScaleBenchmark() async {
    let cell = ProcessInfo.processInfo.environment["SPACEWISE_BENCH_CELL"] ?? ""
    let parts = cell.split(separator: "-").map(String.init)
    guard parts.count == 2, let entries = Int(parts[0]), ["broad", "merged"].contains(parts[1]) else {
        Issue.record("SPACEWISE_BENCH_CELL must look like 100000-broad or 1000000-merged, got \(cell)")
        return
    }
    // SPACEWISE_BENCH_CONTROL=rebuild discards the namespace cache before every checkpoint: the same engine doing the
    // repeated whole-tree rebuild the incremental path replaces. A control for comparison, not the previous code.
    let control = ProcessInfo.processInfo.environment["SPACEWISE_BENCH_CONTROL"] == "rebuild"
    let clock = ContinuousClock()
    let fixture = makeFixture(entries: entries, shape: parts[1])
    let batch = 10_000
    let probeStart = fixture.probeStart
    let urls = [systemURL, dataURL] + fixture.auxiliary.map { URL(fileURLWithPath: $0) }
    let baseline = ScanMemorySample.capture(phase: "fixture")

    var index = ProgressiveIndex.counted()
    var live: [ScanNode] = []
    live.reserveCapacity(fixture.nodes.count)
    var progress = ScanProgress()
    progress.state = .scanning
    var constructing = Duration.zero
    var checkpointing = Duration.zero
    var slowest = Duration.zero
    var mapSeconds = 0.0
    var mapSecondsMax = 0.0
    var mapCostTotal = 0
    var mapCostMax = 0
    var mapTilesMax = 0
    var checkpoints = 0
    var maps = 0
    var fed = 0
    var cumulativeVisits = 0
    var scopes: [Int?] = [nil, managedGroup]
    while fed < probeStart {
        let next = min(probeStart, fed + batch)
        let built = clock.measure {
            live.append(contentsOf: fixture.nodes[fed..<next])
            for id in fed..<next {
                if let old = fixture.transfers[id] {
                    // Scanner order: subtract the old owner's bytes from its ancestry, zero it, then attribute the new owner.
                    index.attribute(
                        logical: live[old].logicalBytes, allocated: live[old].allocatedBytes, to: live[old].parent,
                        nodes: live, subtract: true)
                    live[old].logicalBytes = 0
                    live[old].allocatedBytes = 0
                }
                index.append(live[id])
                if live[id].kind == .file {
                    index.attribute(
                        logical: live[id].logicalBytes, allocated: live[id].allocatedBytes, to: live[id].parent,
                        nodes: live)
                }
            }
        }
        constructing += built
        let sample = clock.measure {
            if control {
                cumulativeVisits += index.namespaceVisitCount
                index.invalidateNamespace()
            }
            for scope in scopes {
                let value = index.snapshot(
                    scanID: UUID(), revision: UInt64(checkpoints + 1),
                    request: ScopeRequest(parent: scope, wantsTreemap: true), nodes: live,
                    urls: urls, coverage: wholeDrive, progress: progress, includeTreemap: true)
                if let map = value.treemap {
                    maps += 1
                    mapSeconds += map.stats.buildSeconds
                    mapSecondsMax = max(mapSecondsMax, map.stats.buildSeconds)
                    mapCostTotal += map.stats.cost
                    mapCostMax = max(mapCostMax, map.stats.cost)
                    mapTilesMax = max(mapTilesMax, map.tiles.count)
                }
                precondition(value.rows.count <= ScopeSnapshot.pageSize)
            }
        }
        checkpointing += sample
        slowest = max(slowest, sample)
        checkpoints += 1
        fed = next
    }
    scopes = []
    let afterLoop = ScanMemorySample.capture(phase: "checkpoints")

    // Cancellation probe: the Data twin's late merge registers the System twin and consumes its previously seen children.
    let probeNodes = Array(fixture.nodes[probeStart...])
    live.append(contentsOf: probeNodes)
    for id in probeStart..<live.count {
        index.append(live[id])
        if live[id].kind == .file {
            index.attribute(
                logical: live[id].logicalBytes, allocated: live[id].allocatedBytes, to: live[id].parent, nodes: live)
        }
    }
    let afterProbeAppend = ScanMemorySample.capture(phase: "probe-append")
    let visitsBefore = index.namespaceVisitCount
    let cancelledAt = Mutex<ContinuousClock.Instant?>(nil)
    let target = fixture.probeSystemTwin
    // The worker owns one mutable index; the probe runs on it in place (a copy would detach every buffer once).
    let box = IndexBox(index)
    index = ProgressiveIndex()
    box.index.namespaceChildren = { parent in
        if parent == target {
            cancelledAt.withLock { $0 = ContinuousClock.now }
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    let nodesForProbe = live
    let probeEnd = await Task.detached { () -> ContinuousClock.Instant in
        let value = box.index.logicalNamespace(nodes: nodesForProbe, urls: urls, coverage: wholeDrive)
        box.probeIdentity = !value.unified
        return ContinuousClock.now
    }.value
    let afterProbeTask = ScanMemorySample.capture(phase: "probe-task")
    let latency = cancelledAt.withLock { $0 }.map { seconds($0.duration(to: probeEnd)) } ?? -1
    let probeVisits = box.index.namespaceVisitCount - visitsBefore
    let probeIdentity = box.probeIdentity
    box.index.namespaceChildren = nil
    // Move the index back out of the box so exactly one owner remains: a retained alias would make the resume detach every buffer.
    index = box.index
    box.index = ProgressiveIndex()
    // Resume: the cache stayed coherent, so the next checkpoint completes the same reconciliation.
    _ = index.logicalNamespace(nodes: live, urls: urls, coverage: wholeDrive)
    let afterResume = ScanMemorySample.capture(phase: "resumed")

    // Settle: the scanner's single finalize pass, then repeated final managed queries.
    let coverage = enumeratedCoverage(of: live)
    let finalizing = clock.measure { Scanner.finalizeCoverage(nodes: &live, coverage: coverage) }
    progress.state = .limited
    var checksum: UInt64 = 0xcbf29ce484222325
    func mix(_ value: UInt64) { checksum = (checksum ^ value) &* 0x100000001b3 }
    var managedAllocated: UInt64 = 0
    var managedLogical: UInt64 = 0
    var managedUnknown = false
    let queries = 1000
    let querying = clock.measure {
        for round in 0..<queries {
            let value = index.snapshot(
                scanID: UUID(), revision: UInt64(checkpoints + 2 + round), request: ScopeRequest(parent: managedGroup),
                nodes: live,
                urls: urls, coverage: wholeDrive, progress: progress)
            managedAllocated = value.scope.allocatedBytes
            managedLogical = value.scope.logicalBytes
            managedUnknown = value.scope.allocationUnknown
        }
    }
    let rootSummary = index.snapshot(
        scanID: UUID(), revision: 1, request: ScopeRequest(parent: nil), nodes: live, urls: urls, coverage: wholeDrive,
        progress: progress
    ).scope
    let finalNamespace = index.logicalNamespace(nodes: live, urls: urls, coverage: wholeDrive, settled: true)
    for value in [
        managedAllocated, managedLogical, UInt64(managedUnknown ? 1 : 0), rootSummary.allocatedBytes,
        rootSummary.logicalBytes,
        UInt64(finalNamespace.listCount(for: nil) ?? 0), UInt64(finalNamespace.listCount(for: managedGroup) ?? 0),
        UInt64(finalNamespace.members.count), UInt64(finalNamespace.hidden.count), UInt64(live.count),
    ] { mix(value) }

    // Member / sample visits behind one final live-limit map of the unified root, counted at the base source.
    let counting = CountingSource(
        base: ProvisionalTreemapSource(index: index, nodes: live, urls: urls, coverage: wholeDrive, progress: progress))
    let source = LogicalTreemapSource(base: counting, namespace: finalNamespace, nodes: live)
    let finalMap = TreemapBuilder.build(
        source: source, scope: nil, provisional: true, limits: .live, isCancelled: { false })
    mix(finalMap.rootWeight)
    mix(UInt64(finalMap.tiles.count))

    // Equivalence with the full-build oracle is checked on the smaller cells (the oracle itself is the heavy path).
    var oracleMatches: Bool? = nil
    if entries <= 100_000 {
        var rootPaths: [Int: String] = [:]
        for (position, id) in index.roots.enumerated() { rootPaths[id] = urls[position].path }
        let expected = LogicalNamespace.build(
            nodes: live, rootPaths: rootPaths, wholeDrive: true, isCancelled: { false }
        ) { index.ranges[$0] ?? 0..<0 }
        oracleMatches =
            expected.members == finalNamespace.members && expected.hidden == finalNamespace.hidden
            && Set(expected.topLevel) == Set(finalNamespace.topLevel)
            && Set(expected.managed) == Set(finalNamespace.managed)
            && expected.managedAggregate.allocatedBytes == finalNamespace.managedAggregate.allocatedBytes
            && expected.managedAggregate.logicalBytes == finalNamespace.managedAggregate.logicalBytes
            && expected.managedAggregate.allocationUnknown == finalNamespace.managedAggregate.allocationUnknown
    }
    let end = ScanMemorySample.capture(phase: "end")

    // Settled construction: the result initializer builds the namespace once (eager path) and a settled map draws on the
    // same ledger. Measured after the memory samples above so the incremental path's numbers stay its own.
    var settledStart = ContinuousClock.now
    let result = ScanResult(
        id: UUID(), started: Date(), ended: Date(), roots: urls, nodes: live, progress: progress, coverage: coverage,
        volumes: [])
    let settledConstruction = seconds(settledStart.duration(to: .now))
    settledStart = .now
    let settledMap = result.treemap(parent: nil)
    let settledMapSeconds = seconds(settledStart.duration(to: .now))
    let settledMemory = ScanMemorySample.capture(phase: "settled")
    #expect(result.namespace.members == finalNamespace.members && result.namespace.hidden == finalNamespace.hidden)
    #expect(result.namespace.managedAggregate.allocatedBytes == finalNamespace.managedAggregate.allocatedBytes)
    #expect(
        settledMap.stats.cost <= TreemapLimits.standard.maxCost && settledMap.rootWeight == rootSummary.allocatedBytes)

    let receipt: [String: Any] = [
        "cell": cell, "control": control ? "forced-rebuild-per-checkpoint" : "incremental", "build": buildConfiguration,
        "entries": live.count, "checkpointBatch": batch, "checkpoints": checkpoints,
        "mapsBuilt": maps, "namespaceBuilds": index.namespaceBuildCount, "topologyVisits": index.namespaceVisitCount,
        "cumulativeTopologyVisits": cumulativeVisits + index.namespaceVisitCount,
        "groupReconciles": index.namespaceReconcileCount, "namespaceAppendWork": index.namespaceAppendWorkCount,
        "mapCostTotal": mapCostTotal, "mapCostMax": mapCostMax, "mapCostLimit": TreemapLimits.live.maxCost,
        "mapTilesMax": mapTilesMax,
        "finalMapReads": [
            "memberWeights": counting.counter.weights, "rows": counting.counter.rows,
            "sampleOrInfo": counting.counter.infos + counting.counter.sampled,
            "selected": counting.counter.selected, "reportedCost": finalMap.stats.cost,
        ],
        "constructionSeconds": seconds(constructing), "checkpointSecondsTotal": seconds(checkpointing),
        "checkpointSecondsMax": seconds(slowest),
        "mapSecondsTotal": mapSeconds, "mapSecondsMax": mapSecondsMax, "finalizeSeconds": seconds(finalizing),
        "finalManagedQueries": queries, "finalManagedQuerySeconds": seconds(querying),
        "settleCount": index.namespaceSettleCount,
        "managedAllocatedBytes": managedAllocated, "managedLogicalBytes": managedLogical,
        "managedUnknown": managedUnknown,
        "rootAllocatedBytes": rootSummary.allocatedBytes, "checksum": String(checksum, radix: 16),
        "cancelProbe": [
            "latencySeconds": latency, "visitsDuringProbe": probeVisits, "returnedIdentity": probeIdentity,
        ],
        "oracleMatches": oracleMatches as Any? ?? NSNull(),
        "memoryMB": [
            "fixtureResident": megabytes(baseline.residentBytes),
            "afterCheckpointsResident": megabytes(afterLoop.residentBytes),
            "afterProbeAppendResident": megabytes(afterProbeAppend.residentBytes),
            "afterProbeTaskResident": megabytes(afterProbeTask.residentBytes),
            "afterResumeResident": megabytes(afterResume.residentBytes),
            "endResident": megabytes(end.residentBytes), "peak": megabytes(end.peakRSSBytes),
        ],
        "settled": [
            "constructionSeconds": settledConstruction, "mapSeconds": settledMapSeconds,
            "mapCost": settledMap.stats.cost, "mapLimited": settledMap.stats.limited,
            "mapTiles": settledMap.tiles.count, "peakMB": megabytes(settledMemory.peakRSSBytes),
            "residentMB": megabytes(settledMemory.residentBytes),
        ],
        "scope": "synthetic core paths only; no filesystem, no UI",
    ]
    if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8)
    {
        print("BENCH \(text)")
    }

    // Gates: counted work, never time.
    if !control {
        #expect(index.namespaceBuildCount == 1)
        #expect(index.namespaceVisitCount <= live.count)  // linear: each node admitted at most once
    }
    #expect(mapCostMax <= TreemapLimits.live.maxCost)
    #expect(index.namespaceSettleCount == 1)
    #expect(probeIdentity && probeVisits < live.count)
    if let oracleMatches { #expect(oracleMatches) }
}
