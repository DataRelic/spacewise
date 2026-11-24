import Foundation
import SpacewiseAppModel
import Testing

@testable import SpacewiseApp
@testable import SpacewiseCore

@MainActor private final class ScanSessionObserver: ScanSessionDelegate {
    var announcements: [String] = []
    var clearedSelection = 0
    var settled = false
    var refusal: ScanResult?
    var sessionMapIsEngaged = false

    func sessionNeedsRender() {}
    func sessionClearsSelection() { clearedSelection += 1 }
    func sessionClearsNotice() {}
    func sessionScanWillStart() {}
    func sessionScanWasRefused(_ result: ScanResult, plan: ScanPlan) { refusal = result }
    func sessionScanDidSettle() { settled = true }
    func sessionAnnounce(_ text: String) { announcements.append(text) }
}

@MainActor struct ScanSessionTests {
    private func result(_ state: ScanState) -> ScanResult {
        var progress = ScanProgress()
        progress.state = state
        progress.allocatedBytes = 1536
        let data = "/System/Volumes/Data"
        return ScanResult(
            id: UUID(), started: Date(), ended: Date(),
            roots: [URL(fileURLWithPath: "/"), URL(fileURLWithPath: data)],
            nodes: [
                ScanNode(id: 0, parent: nil, name: "/", kind: .directory, allocatedBytes: 512, device: 1, inode: 1),
                ScanNode(id: 1, parent: nil, name: data, kind: .directory, allocatedBytes: 1024, device: 2, inode: 1),
                ScanNode(id: 2, parent: 0, name: "System", kind: .directory, allocatedBytes: 512, device: 1, inode: 2),
                ScanNode(id: 3, parent: 1, name: "System", kind: .directory, allocatedBytes: 1024, device: 2, inode: 2),
                ScanNode(id: 4, parent: 2, name: "s", kind: .file, allocatedBytes: 512, device: 1, inode: 3),
                ScanNode(id: 5, parent: 3, name: "d", kind: .file, allocatedBytes: 1024, device: 2, inode: 3),
            ], progress: progress, coverage: LocationCoverage(wholeDrive: true), volumes: [])
    }

    @Test func refusedAndCancelledReplacementsPreserveTheCurrentScope() async throws {
        let session = ScanSession()
        let observer = ScanSessionObserver()
        session.delegate = observer
        let prior = result(.completed)
        session.lastPlan = .internalDisk
        session.settle(prior)
        session.navigate(to: 2)
        await session.treemapTask?.value
        let rows = try #require(session.settledRows())
        let mapRevision = session.treemapRevision
        let clearedSelection = observer.clearedSelection

        session.start(ScanPlan(folder: URL(fileURLWithPath: "/dev")))
        #expect(session.isLive && session.phase == .settled)
        await session.scanTask?.value
        let refusal = try #require(observer.refusal)
        #expect(refusal.progress.state == .invalid)
        #expect(PresentationLabels.selectedRootRefusal(refusal.coverage) != nil)
        #expect(observer.clearedSelection == clearedSelection)

        observer.refusal = nil
        session.start(.internalDisk)
        session.stop()
        await session.scanTask?.value
        #expect(observer.refusal == nil)
        #expect(session.result?.id == prior.id && session.lastPlan?.startup == true)
        #expect(session.currentParent == 2 && session.treemapRevision == mapRevision)
        #expect(session.settledRows()?.ids == rows.ids)
        #expect(observer.clearedSelection == clearedSelection)
        #expect(session.phase == .settled && !session.isLive)
        session.endCompletionConfirmation()
    }

    @Test(arguments: [LogicalNamespace.managedGroupID, 2])
    func stoppedDriveScopeReopensAtItsRetainedRoots(_ liveParent: Int) async throws {
        let session = ScanSession()
        let observer = ScanSessionObserver()
        session.delegate = observer
        session.lastPlan = .internalDisk
        session.scanTask = Task {}
        session.scopeRequest = ScopeRequest(parent: liveParent, offset: 256, generation: 1)
        let live = result(.completed)
        let oldMap = live.logicalTreemap(parent: liveParent)
        session.setTreemap(oldMap)
        session.pendingLiveTreemap = oldMap
        #expect(live.logicalSummary(parent: liveParent).crumbs.last?.id == liveParent)

        session.stop()
        #expect(ScreenStateBuilder.build(session.screenInputs(volume: nil)).state.status?.kind == .stopping)
        session.settle(result(.cancelled))
        let pendingMap = try #require(session.treemapTask)
        #expect(session.treemapModel == nil)
        #expect(session.pendingLiveTreemap == nil)
        await pendingMap.value

        let screen = ScreenStateBuilder.build(session.screenInputs(volume: nil))
        #expect(session.currentParent == nil && session.scopeRequest.offset == 0 && !session.canGoUp)
        #expect(screen.state.status?.kind == .stopped)
        #expect(observer.announcements.last == screen.state.status?.title)
        #expect(observer.clearedSelection == 1 && observer.settled)
        #expect(screen.state.summary?.crumbs.isEmpty == true)
        #expect(screen.state.summary?.allocatedBytes == 1536)
        #expect(Set(try #require(session.settledRows()).ids) == [0, 1])
        let map = try #require(session.treemapModel)
        #expect(map.scope == nil && map.tiles.first?.weight == 1536)
        #expect(map.tileIndex(forNode: 0) != nil && map.tileIndex(forNode: 1) != nil)

        session.navigate(to: 1)
        let reopened = ScreenStateBuilder.build(session.screenInputs(volume: nil))
        #expect(reopened.state.summary?.crumbs.map(\.id) == [1])
        #expect(reopened.state.summary?.allocatedBytes == 1024)
        #expect(session.settledRows()?.node(at: 0)?.id == 3)
        session.treemapTask?.cancel()
        session.endCompletionConfirmation()
    }

    @Test func stopBeforeSettlementWinsOverWorkerSuccess() async throws {
        let session = ScanSession()
        let observer = ScanSessionObserver()
        session.delegate = observer
        session.lastPlan = .internalDisk
        session.scanTask = Task {}
        let mergedFolder = 2
        session.scopeRequest = ScopeRequest(parent: mergedFolder)

        // The worker finished its index and namespace. Stop reaches the session before that value is installed.
        let workerValue = result(.completed)
        session.stop()
        session.settle(workerValue)
        await session.treemapTask?.value
        let screen = ScreenStateBuilder.build(session.screenInputs(volume: nil))
        #expect(session.result?.progress.state == .cancelled)
        #expect(session.currentParent == mergedFolder && session.result?.namespace.isMerged(mergedFolder) == true)
        #expect(screen.state.status?.kind == .stopped && observer.announcements.last == screen.state.status?.title)
        #expect(screen.state.summary?.crumbs.last?.id == mergedFolder)
        #expect(screen.state.summary?.allocatedBytes == 1536)
        #expect(Set(try #require(session.settledRows()).ids) == [4, 5])
        #expect(session.treemapModel?.scope == mergedFolder)
        session.endCompletionConfirmation()
    }

    @Test func stoppedWideFolderKeepsItsSizeOrderAndDiscardsAnObsoleteRequest() async throws {
        let plan = ScanPlan(folder: .temporaryDirectory)
        let folders = [
            ScanNode(id: 0, parent: nil, name: "Fixture", kind: .directory, device: 1, inode: 1),
            ScanNode(id: 1, parent: 0, name: "Wide", kind: .directory, device: 1, inode: 2),
            ScanNode(id: 2, parent: 0, name: "Empty", kind: .directory, device: 1, inode: 3),
        ]
        let files = (3..<1503).map { id in
            ScanNode(
                id: id, parent: 1, name: String(id), kind: .file, allocatedBytes: id <= 4 ? 0 : UInt64(id),
                issue: id == 4 ? .metadata : nil, device: 1, inode: UInt64(id + 1))
        }
        let result = await Task {
            await Scanner.scan(
                plan: plan,
                diagnostics: { sample in
                    if sample.phase == "indexing" { withUnsafeCurrentTask { $0?.cancel() } }
                }, injectedNodes: folders + files, injectedFailure: nil, update: { _ in })
        }.value
        try #require(result.progress.cancelled && !result.childrenAreRanked(of: 1))

        let session = ScanSession()
        session.lastPlan = plan
        session.topLevel = 0
        session.settle(result)
        session.navigate(to: 1)
        let pending = ScreenStateBuilder.build(session.screenInputs(volume: nil)).state
        #expect(pending.source == nil && pending.total == files.count)
        #expect(pending.status?.kind == .stopped && pending.empty?.title == ProductCopy.Waiting.orderingTitle)
        let obsolete = try #require(session.rowRankingTask)
        session.navigate(to: 2)
        await obsolete.value
        #expect(session.settledRows()?.count == 0)

        session.navigate(to: 1)
        #expect(session.settledRows() == nil)
        await session.rowRankingTask?.value
        let rows = try #require(session.settledRows())
        #expect(Array(rows.ids) == Array((5..<1503).reversed()) + [3, 4])
        let ready = ScreenStateBuilder.build(session.screenInputs(volume: nil)).state
        #expect(ready.status?.kind == .stopped && ready.source?.count == files.count)
        session.treemapTask?.cancel()
        session.endCompletionConfirmation()
    }
}
