import Darwin
import Foundation
import Testing

@testable import SpacewiseCore

@Test func boundedCoverageCounts() {
    var coverage = LocationCoverage(limit: 1)
    coverage.record(path: "/a", nodeID: nil, operation: .fstatat, reason: .denied)
    coverage.record(path: "/a", nodeID: nil, operation: .fstatat, reason: .denied)
    #expect(coverage.records[0].count == 2)
    coverage.record(path: "/b", nodeID: nil, operation: .fstatat, reason: .denied)
    #expect(coverage.truncated && coverage.exactUniqueLocations == nil)
    #expect(coverage.events == 3)
}

@Test func injectedDirectoryFailuresAreSingleEvents() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    for operation in [CoverageOperation.fdopendir, .readdir] {
        let result = await Scanner.scan(
            plan: ScanPlan(folder: root), injectedFailure: { op, _ in op == operation ? EIO : nil }, update: { _ in })
        #expect(result.coverage.events == 1)
        #expect(result.progress.issues[.enumeration] == 1)
        #expect(result.nodes[0].allocationUnknown)
    }
    let empty = await Scanner.scan(plan: ScanPlan(folder: root), update: { _ in })
    #expect(!empty.nodes[0].allocationUnknown)
    #expect(empty.coverageStatus(for: 0) == .measured)
    try Data().write(to: root.appendingPathComponent("entry"))
    let denied = await Scanner.scan(
        plan: ScanPlan(folder: root), injectedFailure: { op, _ in op == .fstatat ? EACCES : nil }, update: { _ in })
    #expect(denied.coverage.events == 1)
    #expect(denied.coverage.records[0].parentID == 0)
    #expect(denied.coverageStatus(for: 0) == .partial)
}

@Test func cancellationBeforeEnumeration() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    let worker = Task {
        await Scanner.scan(
            plan: ScanPlan(folder: root),
            update: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
    }
    let result = await worker.value
    #expect(!Task.isCancelled)
    #expect(result.progress.state == .cancelled)
    #expect(result.nodes[0].allocationUnknown)
    #expect(result.coverageStatus(for: 0) != .measured)
}

@Test func cancellationWithPendingDirectory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("pending"), withIntermediateDirectories: false)
    let worker = Task {
        await Scanner.scan(
            plan: ScanPlan(folder: root),
            injectedFailure: { operation, _ in
                if operation == .fstatat { withUnsafeCurrentTask { $0?.cancel() } }
                return nil
            }, update: { _ in })
    }
    let result = await worker.value
    #expect(!Task.isCancelled)
    #expect(result.progress.state == .cancelled)
    #expect(result.nodes.count == 2)
    #expect(result.nodes.allSatisfy { $0.allocationUnknown })
    #expect(result.coverage.enumeration[1] == .unopened)
    #expect(result.coverageStatus(for: 0) != .measured)
}

@Test func syntheticUnknownIssuesPropagate() {
    for issue in [CoverageIssue.placeholder, .volumeBoundary] {
        var nodes = [
            ScanNode(id: 0, parent: nil, name: "root", kind: .directory, device: 1, inode: 1),
            ScanNode(id: 1, parent: 0, name: "child", kind: .directory, device: 1, inode: 2),
        ]
        nodes[1].issue = issue
        var coverage = LocationCoverage()
        coverage.enumeration[0] = .enumerated
        coverage.enumeration[1] = .unopened
        Scanner.finalizeCoverage(nodes: &nodes, coverage: coverage)
        #expect(nodes.allSatisfy { $0.allocationUnknown })
        #expect(nodes[0].allocatedBytes == 0)
    }
}

@Test func selectedVolumeIdentityPolicy() {
    let startup: Set<UInt64> = [1, 2]
    #expect(SelectedVolumeMetadata(identity: 1, local: true, removable: false).allowed(in: startup))
    #expect(SelectedVolumeMetadata(identity: 2, local: true, removable: false).allowed(in: startup))
    // A local image mounted at an ordinary path still has a different identity.
    #expect(!SelectedVolumeMetadata(identity: 3, local: true, removable: false).allowed(in: startup))
    #expect(!SelectedVolumeMetadata(identity: 1, local: false, removable: false).allowed(in: startup))
    #expect(!SelectedVolumeMetadata(identity: 1, local: true, removable: true).allowed(in: startup))
    #expect(SelectedVolumeMetadata(identity: 1, local: true, removable: false).rejection(in: startup) == nil)
    #expect(
        SelectedVolumeMetadata(identity: 3, local: true, removable: false).rejection(in: startup)
            == "could not verify this volume is on the startup drive")
    #expect(
        SelectedVolumeMetadata(identity: 1, local: false, removable: true).rejection(in: startup)
            == "network or non-local volume")
    #expect(Set([UInt64(1), 1, 2]).count == 2)
    #expect(ScanPolicy().exclusion(for: "/Users/example/project/dev") == nil)
}

@Test func excludedAliasHasNoCapacityContext() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    try FileManager.default.createSymbolicLink(
        atPath: root.appendingPathComponent("alias").path, withDestinationPath: "/dev")
    let result = await Scanner.scan(plan: ScanPlan(folder: root.appendingPathComponent("alias/fd")), update: { _ in })
    #expect(result.nodes.isEmpty)
    #expect(result.volumes.isEmpty)
    #expect(result.coverage.records.first?.reason == .policyExcluded)
    let invalid = await Scanner.scan(plan: ScanPlan(folder: root.appendingPathComponent("missing")), update: { _ in })
    #expect(invalid.volumes.isEmpty)
    var coverage = LocationCoverage(limit: 1)
    coverage.record(path: "/a", nodeID: nil, operation: .open, reason: .denied)
    coverage.record(path: "/b", nodeID: nil, operation: .open, reason: .denied)
    #expect(coverage.retainedUniqueLocations == 1)
    #expect(coverage.exactUniqueLocations == nil)
}

@Test(arguments: [
    (UInt32(0), "network or non-local volume"),
    (UInt32(MNT_LOCAL | MNT_REMOVABLE), "removable volume"),
])
func rejectedVolumeNamesItsReason(flags: UInt32, expected: String) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    let result = await Scanner.scan(
        plan: ScanPlan(folder: root), injectedVolumeFlags: { _ in flags }, injectedFailure: nil, update: { _ in })
    #expect(result.nodes.isEmpty)
    let record = try #require(result.coverage.records.first { $0.reason == .policyExcluded })
    #expect(record.operation == .rootVolume)
    #expect(record.policyDetail == expected)
}

@Test func localFixedVolumeIsNotRejected() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    let result = await Scanner.scan(
        plan: ScanPlan(folder: root), injectedVolumeFlags: { _ in UInt32(MNT_LOCAL) }, injectedFailure: nil,
        update: { _ in })
    #expect(result.nodes.count == 1)
    #expect(result.coverage.records.isEmpty)
}

@Test(arguments: [(EACCES, CoverageIssue.denied), (ENOENT, .vanished), (EIO, .metadata), (ENAMETOOLONG, .metadata)])
func entryFailureKeepsTheRawErrno(code: Int32, category: CoverageIssue) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    try Data().write(to: root.appendingPathComponent("entry"))
    let result = await Scanner.scan(
        plan: ScanPlan(folder: root), injectedFailure: { op, _ in op == .fstatat ? code : nil }, update: { _ in })
    let record = try #require(result.coverage.records.first)
    #expect(record.reason == category)
    #expect(record.errnoCode == code)
}

@Test func directoryFailuresKeepTheRawErrno() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    for operation in [CoverageOperation.fdopendir, .readdir] {
        let result = await Scanner.scan(
            plan: ScanPlan(folder: root), injectedFailure: { op, _ in op == operation ? EMFILE : nil }, update: { _ in }
        )
        let record = try #require(result.coverage.records.first)
        #expect(record.operation == operation && record.reason == .enumeration)
        #expect(record.errnoCode == EMFILE)
    }
}

@Test func openFailureAndMissingRootKeepTheRawErrno() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    let locked = root.appendingPathComponent("locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    let result = await Scanner.scan(plan: ScanPlan(folder: root), update: { _ in })
    let denied = try #require(result.coverage.records.first { $0.operation == .open })
    #expect(denied.reason == .denied && denied.errnoCode == EACCES)
    let missing = await Scanner.scan(plan: ScanPlan(folder: root.appendingPathComponent("missing")), update: { _ in })
    let record = try #require(missing.coverage.records.first)
    #expect(record.reason == .vanished && record.errnoCode == ENOENT)
    // Policy and identity records carry no errno.
    var coverage = LocationCoverage()
    coverage.record(
        path: "/dev", nodeID: nil, operation: .selectRoot, reason: .policyExcluded, policyDetail: "device filesystem")
    #expect(coverage.records[0].errnoCode == nil)
}

/// A folder that cannot be opened must not stay "unopened" (not read yet) or "partial" (being read): it will never be read.
@Test func folderThatFailsToOpenEndsInATerminalState() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    let locked = root.appendingPathComponent("locked")
    let readable = root.appendingPathComponent("readable")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    let result = await Scanner.scan(plan: ScanPlan(folder: root), update: { _ in })
    let lockedID = try #require(result.nodes.firstIndex { $0.name == "locked" })
    let readableID = try #require(result.nodes.firstIndex { $0.name == "readable" })
    #expect(result.coverage.enumeration[lockedID]?.rawValue == "openFailed")
    #expect(result.coverage.enumeration[readableID] == .enumerated)
    #expect(result.coverageStatus(for: lockedID) == .denied)
}

@Test func folderThatFailsToListEndsInATerminalState() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    let result = await Scanner.scan(
        plan: ScanPlan(folder: root), injectedFailure: { op, _ in op == .fdopendir ? EMFILE : nil }, update: { _ in })
    #expect(result.coverage.enumeration[0]?.rawValue == "openFailed")
    #expect(result.coverageStatus(for: 0) == .unavailable)
}
