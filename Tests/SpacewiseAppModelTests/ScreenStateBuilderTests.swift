import Foundation
import SpacewiseAppModel
import SpacewiseCore
import SpacewiseFixtures
import Testing

@MainActor @Suite struct ScreenStateBuilderTests {
    private func inputs(_ phase: ScanPhase, now: Date = Date()) -> ScreenInputs {
        ScreenInputs(
            phase: phase, scopeTitle: "Example", isFolderScope: true, volume: nil, now: now, liveProgress: nil,
            liveSnapshot: nil, liveSource: nil, requestOffset: 0, result: nil, settledSource: nil,
            currentParent: 0, treemapModel: nil, treemapRevision: 3, hasPendingTreemap: false, canGoUp: false,
            isLive: phase == .scanning || phase == .stopping)
    }

    @Test func theReadyScreenHasNoRowsMapOrBanners() {
        let screen = ScreenStateBuilder.build(inputs(.ready))
        #expect(screen.state.phase == .ready)
        #expect(screen.state.source == nil)
        #expect(screen.state.treemap == nil)
        #expect(screen.state.status == nil)
        #expect(screen.windowTitle == ProductCopy.App.name)
    }

    @Test func aScanBeforeItsFirstSnapshotWaits() {
        var input = inputs(.scanning)
        input.requestOffset = ScopeSnapshot.pageSize
        let screen = ScreenStateBuilder.build(input)
        #expect(screen.state.provisional)
        #expect(screen.state.empty?.title == ProductCopy.Waiting.title)
        #expect(screen.state.canPage && screen.state.canGoPrevious && !screen.state.canGoNext)
        #expect(screen.state.treemap?.message?.title == ProductCopy.Map.waitingTitle)
        #expect(screen.state.treemap?.revision == 3)
        #expect(screen.windowTitle == "Example")
    }

    @Test func aLiveSnapshotFillsTheListAndPaging() {
        let snapshot = PresentationFixtures.scenario(.scanning).snapshot
        var input = inputs(.scanning)
        input.liveSnapshot = snapshot
        input.liveSource = SnapshotRows(snapshot)
        input.liveProgress = snapshot.progress
        let screen = ScreenStateBuilder.build(input)
        let page = LivePage(snapshot)
        #expect(screen.state.source === input.liveSource)
        #expect(screen.state.total == snapshot.discoveredChildren)
        #expect(screen.state.canPage == page.isPaged)
        #expect(screen.state.canGoNext == page.hasNext)
        #expect(screen.state.status?.kind == .scanning && screen.state.status?.actions == [.stop])
    }

    @Test func aSettledResultShowsItsRowsAndAgesIntoAFreshnessBanner() throws {
        let fixture = PresentationFixtures.scenario(.complete)
        var input = inputs(.settled, now: fixture.result.ended.addingTimeInterval(125))
        input.result = fixture.result
        input.settledSource = SettledRows(result: fixture.result, parent: 0)
        let fresh = ScreenStateBuilder.build(input)
        #expect(fresh.state.source === input.settledSource)
        #expect(fresh.state.total == input.settledSource?.count)
        #expect(fresh.state.status == nil)  // complete and not just finished: no line
        #expect(fresh.state.treemap?.message?.title == ProductCopy.Map.buildingTitle)
        #expect(fresh.windowSubtitle.hasSuffix("2 minutes ago"))

        input.now = fixture.result.ended.addingTimeInterval(ResultFreshness.staleAfter)
        let stale = ScreenStateBuilder.build(input)
        #expect(stale.state.status?.kind == .stale)

        input.now = fixture.result.ended.addingTimeInterval(1)
        input.confirmsCompletion = true
        #expect(ScreenStateBuilder.build(input).state.status?.kind == .complete)
    }

    @Test func aSettledPhaseWithoutRowsBuildsNoList() {
        let fixture = PresentationFixtures.scenario(.complete)
        var input = inputs(.settled)
        input.result = fixture.result
        let screen = ScreenStateBuilder.build(input)
        #expect(screen.state.source == nil)
        #expect(screen.state.status == nil)
    }
}
