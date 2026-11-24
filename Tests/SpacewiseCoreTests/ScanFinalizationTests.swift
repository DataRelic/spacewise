import Foundation
import Synchronization
import Testing

@testable import SpacewiseCore

struct ScanFinalizationTests {
    @Test func cancellationInterruptsFinalRankingAndKeepsEveryChild() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let nodes =
            [
                ScanNode(id: 0, parent: nil, name: "Fixture", kind: .directory, device: 1, inode: 1)
            ]
            + (1...2500).map { id in
                ScanNode(
                    id: id, parent: 0, name: "file-\(id)", kind: .file,
                    logicalBytes: UInt64(id), allocatedBytes: UInt64(id * 512), device: 1, inode: UInt64(id + 1))
            }
        let checkpoints = Mutex<[String]>([])
        let progress = Mutex<[ScanState]>([])
        let result = await Task {
            await Scanner.scan(
                plan: ScanPlan(folder: fixture.root),
                diagnostics: { sample in
                    checkpoints.withLock { $0.append(sample.phase) }
                    if sample.phase == "indexing" { withUnsafeCurrentTask { $0?.cancel() } }
                }, injectedNodes: nodes, injectedFailure: nil,
                update: { value in progress.withLock { $0.append(value.state) } })
        }.value
        #expect(checkpoints.withLock { $0.suffix(2) } == ["reduced", "indexing"])
        #expect(progress.withLock { $0 } == [.scanning, .cancelled])
        #expect(result.progress.cancelled)
        #expect(!result.childrenAreRanked(of: 0))
        #expect(result.childIDs(of: 0).sorted() == Array(1...2500))
        #expect(result.logicalSummary(parent: 0).allocatedBytes == result.progress.allocatedBytes)
        let map = result.logicalTreemap(parent: 0)
        #expect(map.scope == 0)
        #expect(map.tileIndex(forNode: 2500) != nil)
        #expect(map.tiles.first?.weight == result.progress.allocatedBytes)
    }

    @Test func cancellationDuringFinalNamespaceKeepsPhysicalVolumes() async {
        let roots = [URL(fileURLWithPath: "/"), URL(fileURLWithPath: StartupDrive.dataVolumePath)]
        let discovery = DriveDiscovery(roots: roots, unresolved: [])
        let nodes = [
            ScanNode(id: 0, parent: nil, name: "/", kind: .directory, device: 1, inode: 1),
            ScanNode(id: 1, parent: nil, name: StartupDrive.dataVolumePath, kind: .directory, device: 2, inode: 1),
            ScanNode(id: 2, parent: 0, name: "System", kind: .directory, device: 1, inode: 2),
            ScanNode(id: 3, parent: 1, name: "System", kind: .directory, device: 2, inode: 2),
            ScanNode(id: 4, parent: 2, name: "system-only", kind: .file, allocatedBytes: 512, device: 1, inode: 3),
            ScanNode(id: 5, parent: 3, name: "data-only", kind: .file, allocatedBytes: 1024, device: 2, inode: 3),
        ]
        let visited = Mutex<[Int]>([])
        let states = Mutex<[ScanState]>([])
        let result = await Task {
            await Scanner.scan(
                plan: .internalDisk, injectedDiscovery: { discovery }, injectedNodes: nodes,
                namespaceChildren: { parent in
                    visited.withLock { $0.append(parent) }
                    if parent == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                }, injectedFailure: nil, update: { value in states.withLock { $0.append(value.state) } })
        }.value
        #expect(visited.withLock { $0.contains(2) })
        #expect(states.withLock { $0 } == [.scanning, .cancelled])
        #expect(result.progress.cancelled && !result.namespace.unified)
        #expect(result.settledScope(for: 2) == nil)
        #expect(result.settledScope(for: LogicalNamespace.managedGroupID) == nil)
        #expect(result.logicalSummary(parent: nil).allocatedBytes == 1536)
        #expect(result.logicalChildIDs(of: 2).elementsEqual([4]))
        #expect(result.logicalChildIDs(of: 3).elementsEqual([5]))
    }

    @Test func terminalNotificationObservesCommittedResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for i in 0..<10 { try Data([1]).write(to: fixture.root.appending(path: "file-\(i)")) }
        let snapshots = Mutex<[ScopeSnapshot]>([])
        let terminal = Mutex<[ScanState]>([])
        let result = await Task {
            await Scanner.scan(
                plan: ScanPlan(folder: fixture.root), scopeRequest: { ScopeRequest(parent: 0) },
                scopeUpdate: { value in snapshots.withLock { $0.append(value) } },
                update: { value in
                    guard value.finished else { return }
                    #expect(snapshots.withLock { $0.last?.discoveredChildren } == 10)
                    terminal.withLock { $0.append(value.state) }
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }.value
        let last = try #require(snapshots.withLock { $0.last })
        #expect(!last.provisional && last.progress.state == result.progress.state)
        #expect(terminal.withLock { $0 } == [.completed])
        #expect(result.progress.state == .completed && result.childrenAreRanked(of: 0))
        #expect(last.rows.map(\.node.id).elementsEqual(result.childIDs(of: 0)))
    }
}
