import Foundation
import Testing

@testable import SpacewiseCore

// Category totals (`measuredCategories`) reconcile with the scan totals and carry "unknown" through every root.

@Test func ownedCategoryReconciliation() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Sample.app"), withIntermediateDirectories: false)
    let file = root.appendingPathComponent("Sample.app/sparse")
    #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 8 * 1024 * 1024)
    try handle.close()
    try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("alias"))
    let result = await Scanner.scan(plan: ScanPlan(folder: root), update: { _ in })
    let totals = result.measuredCategories()
    #expect(totals.values.reduce(UInt64(0)) { $0 + $1.logicalBytes } == result.progress.logicalBytes)
    #expect(totals.values.reduce(UInt64(0)) { $0 + $1.allocatedBytes } == result.progress.allocatedBytes)
    #expect(
        result.nodes.filter { $0.hardLinkOwner != nil }.allSatisfy { $0.logicalBytes == 0 && $0.allocatedBytes == 0 })
}

@Test(arguments: [false, true]) func weightedCategoryTotalsStayCachedAndKeepUnknown(deep: Bool) {
    _ = measureWeightedCategories(deep: deep, nodes: deep ? 20_000 : 10_000, queries: 1_000)
}

struct WeightedCategoryMeasurement {
    let nodes: Int
    let construction: TimeInterval
    let queries: TimeInterval
    let memory: ScanMemorySample
}

/// A developer-managed root holding `nodes` weighted entries, either one wide folder or one chain `nodes` deep. The
/// last entry has unknown allocation, so the category must report "unknown" however often it is read.
func measureWeightedCategories(deep: Bool, nodes count: Int, queries: Int) -> WeightedCategoryMeasurement {
    var nodes = [ScanNode(id: 0, parent: nil, name: "root", kind: .directory, device: 0, inode: 0)]
    for id in 1...count {
        nodes.append(
            ScanNode(
                id: id, parent: deep ? id - 1 : 0, name: "weighted", kind: deep ? .directory : .file,
                logicalBytes: 4096, allocatedBytes: 512, allocationUnknown: id == count, device: 0, inode: UInt64(id)))
    }
    let start = Date()
    let result = ScanResult(
        id: UUID(), started: start, ended: start, roots: [URL(fileURLWithPath: "/Users/fixture/Library/Developer")],
        nodes: nodes, progress: ScanProgress(), volumes: [])
    let construction = Date().timeIntervalSince(start)
    let query = Date()
    var everyAnswerUnknown = true
    for _ in 0..<queries where result.measuredCategories()[.developerManaged]?.allocationUnknown != true {
        everyAnswerUnknown = false
    }
    #expect(everyAnswerUnknown, "deep=\(deep): a category holding an unknown entry must stay unknown")
    return WeightedCategoryMeasurement(
        nodes: nodes.count, construction: construction, queries: Date().timeIntervalSince(query),
        memory: ScanMemorySample.capture(phase: "weighted", nodeCount: nodes.count))
}

@Test func partialMultiRootCategories() {
    var nodes: [ScanNode] = []
    func add(
        _ parent: Int?, _ name: String, _ kind: NodeKind, _ logical: UInt64 = 0, _ allocated: UInt64 = 0,
        unknown: Bool = false, owner: Int? = nil
    ) {
        nodes.append(
            ScanNode(
                id: nodes.count, parent: parent, name: name, kind: kind, logicalBytes: logical,
                allocatedBytes: allocated, allocationUnknown: unknown, hardLinkOwner: owner, device: 1,
                inode: UInt64(nodes.count)))
    }
    add(nil, "Data", .directory, 100, 40, unknown: true)
    add(0, "Users", .directory)
    add(1, "person", .directory)
    add(2, "Sample.app", .package, 100, 40)
    add(3, "payload", .file, 100, 40)
    add(2, "alias", .file, owner: 4)
    add(2, "unread", .directory, unknown: true)
    add(0, "System", .directory)
    add(7, "payload", .file, 200, 80)
    add(nil, "aux", .directory, 300, 120, unknown: true)
    add(9, "payload", .file, 300, 120)
    var progress = ScanProgress()
    progress.logicalBytes = 600
    progress.allocatedBytes = 240
    progress.state = .limited
    for reason in [CoverageIssue.unmounted, .metadata] {
        var coverage = LocationCoverage(wholeDrive: true)
        coverage.record(path: "/unread", nodeID: 6, operation: .metadata, reason: reason)
        let result = ScanResult(
            id: UUID(), started: Date(), ended: Date(),
            roots: [URL(fileURLWithPath: "/System/Volumes/Data"), URL(fileURLWithPath: "/aux")],
            nodes: nodes, progress: progress, coverage: coverage, volumes: [])
        let totals = result.measuredCategories()
        #expect(totals.values.reduce(0) { $0 + $1.logicalBytes } == progress.logicalBytes)
        #expect(totals.values.reduce(0) { $0 + $1.allocatedBytes } == progress.allocatedBytes)
        #expect(totals[.personal]?.logicalBytes == 100)
        #expect(totals[.systemManaged]?.logicalBytes == 500)
        #expect(totals[.personal]?.allocationUnknown == true)
        #expect(totals[.systemManaged]?.allocationUnknown == true)
        #expect(coverage.actionableEvents == (reason == .metadata ? 1 : 0))
    }
}
