import SpacewiseAppModel
import SpacewiseCore
import Testing

private func state(
    _ phase: ScanPhase, live: Bool = false, stopping: Bool = false,
    plan: Bool = false, result: Bool = false, location: Bool = false, open: Bool = false,
    up: Bool = false, offset: Int = 0, next: Bool = false
) -> CommandState {
    CommandState(
        phase: phase, isLive: live, isStopping: stopping, hasLastPlan: plan,
        hasResult: result, selectionHasLocation: location, selectionCanOpen: open, canGoUp: up,
        pageOffset: offset, hasNextPage: next)
}

@Suite struct CommandStateTests {
    @Test func readyOffersOnlyTheTwoScans() {
        let ready = state(.ready)
        let enabled = AppCommand.allCases.filter { ready.isEnabled($0) }
        #expect(enabled == [.scanInternal, .scanFolder])
    }

    @Test func aRunningScanCanBeStoppedOnceAndBlocksNewScans() {
        let scanning = state(.scanning, live: true, plan: true)
        #expect(scanning.isEnabled(.stopScan))
        #expect(!scanning.isEnabled(.scanInternal))
        #expect(!scanning.isEnabled(.scanFolder))
        #expect(!scanning.isEnabled(.rescan))
        #expect(!scanning.isEnabled(.showScanDetails))
        #expect(scanning.isEnabled(.toggleList))
        let stopping = state(.stopping, live: true, stopping: true, plan: true)
        #expect(!stopping.isEnabled(.stopScan))
    }

    @Test func rescanNeedsAPlanAndAResult() {
        #expect(state(.settled, plan: true, result: true).isEnabled(.rescan))
        #expect(!state(.settled, plan: false, result: true).isEnabled(.rescan))
        #expect(!state(.settled, plan: true, result: false).isEnabled(.rescan))
    }

    @Test func scanDetailsDescribeOnlyASettledResult() {
        #expect(state(.settled, result: true).canShowScanDetails)
        #expect(state(.settled, result: true).isEnabled(.showScanDetails))
        #expect(!state(.scanning, live: true, result: true).canShowScanDetails)
        #expect(!state(.settled, result: false).canShowScanDetails)
    }

    @Test func openingFolderNeedsAnOpenableSelectionOutsideReady() {
        #expect(state(.settled, open: true).isEnabled(.openFolder))
        #expect(!state(.settled, open: false).isEnabled(.openFolder))
        #expect(!state(.ready, open: true).isEnabled(.openFolder))
    }

    @Test func upAndTopLevelFollowCanGoUp() {
        #expect(state(.settled, up: true).isEnabled(.enclosingFolder))
        #expect(state(.settled, up: true).isEnabled(.topLevel))
        #expect(!state(.settled, up: false).isEnabled(.enclosingFolder))
        #expect(!state(.settled, up: false).isEnabled(.topLevel))
    }

    @Test func pagingIsOnlyForLiveScopes() {
        #expect(state(.scanning, live: true, offset: 256).isEnabled(.previousPage))
        #expect(!state(.scanning, live: true, offset: 0).isEnabled(.previousPage))
        #expect(state(.scanning, live: true, next: true).isEnabled(.nextPage))
        #expect(!state(.scanning, live: true, next: false).isEnabled(.nextPage))
        #expect(!state(.settled, offset: 256, next: true).isEnabled(.previousPage))
        #expect(!state(.settled, offset: 256, next: true).isEnabled(.nextPage))
    }

    @Test func showInFinderFollowsTheSelectionLocation() {
        #expect(state(.settled, location: true).isEnabled(.showInFinder))
        #expect(!state(.settled, location: false).isEnabled(.showInFinder))
    }
}

@Suite struct ItemCommandTests {
    private func settled(location: Bool, open: OpenBehavior, quickLook: Bool) -> CommandState {
        CommandState(
            phase: .settled, isLive: false, isStopping: false, hasLastPlan: true,
            hasResult: true, selectionHasLocation: location, selectionCanOpen: false, canGoUp: false,
            pageOffset: 0, hasNextPage: false, selectionOpen: open, selectionCanQuickLook: quickLook)
    }

    @Test func openNeedsALocationAndTheOpenRule() {
        #expect(settled(location: true, open: .open, quickLook: true).isEnabled(.openItem))
        #expect(!settled(location: true, open: .showInFinderOnly, quickLook: true).isEnabled(.openItem))
        #expect(!settled(location: false, open: .open, quickLook: true).isEnabled(.openItem))
    }

    @Test func itemsHeldBackFromOpenStillOfferShowInFinder() {
        let held = settled(location: true, open: .showInFinderOnly, quickLook: false)
        #expect(held.isEnabled(.showInFinder))
        #expect(!held.isEnabled(.openItem))
    }

    @Test func quickLookNeedsALocationAndAPreviewableItem() {
        #expect(settled(location: true, open: .open, quickLook: true).isEnabled(.quickLook))
        #expect(!settled(location: true, open: .open, quickLook: false).isEnabled(.quickLook))
        #expect(!settled(location: false, open: .open, quickLook: true).isEnabled(.quickLook))
    }

    @Test func nothingSelectedOffersNoItemCommands() {
        let none = state(.settled, plan: true, result: true)
        #expect(!none.isEnabled(.openItem))
        #expect(!none.isEnabled(.quickLook))
        #expect(!none.isEnabled(.showInFinder))
    }

    @Test func theFilterIsOfferedWhenAListIsShown() {
        #expect(!state(.ready).isEnabled(.filterList))
        #expect(state(.scanning, live: true).isEnabled(.filterList))
        #expect(state(.settled, result: true).isEnabled(.filterList))
    }
}
