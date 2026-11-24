import SpacewiseAppModel
import SpacewiseCore
import SpacewiseFixtures
import Testing

@Suite struct ScopeNavigationTests {
    private func canGoUp(_ phase: ScanPhase, _ parent: Int?, _ top: Int?, live: Bool, snapshot: Bool) -> Bool {
        ScopeNavigation.canGoUp(
            phase: phase, currentParent: parent, topLevel: top, isLive: live, hasLiveSnapshot: snapshot)
    }

    @Test func movingToAnotherFolderStartsAtItsFirstPageWithANewGeneration() {
        let current = ScopeRequest(parent: 4, offset: 512, generation: 7, wantsTreemap: false)
        let move = ScopeNavigation.move(to: 9, from: current)
        #expect(move.changesScope)
        #expect(move.request == ScopeRequest(parent: 9, offset: 0, generation: 8, wantsTreemap: true))
    }

    @Test func turningAPageStaysInTheScope() {
        let current = ScopeRequest(parent: 4, offset: 0, generation: 2, wantsTreemap: true)
        let move = ScopeNavigation.move(to: 4, offset: 256, from: current)
        #expect(!move.changesScope)
        #expect(move.request.offset == 256)
        #expect(move.request.generation == 3)
    }

    @Test func movingBetweenTheTopLevelAndAFolderChangesScope() {
        let top = ScopeRequest()
        #expect(ScopeNavigation.move(to: 0, from: top).changesScope)
        #expect(!ScopeNavigation.move(to: nil, from: top).changesScope)
        #expect(ScopeNavigation.move(to: nil, from: ScopeRequest(parent: 0)).changesScope)
    }

    @Test func aNegativeOffsetIsClampedToTheFirstPage() {
        #expect(ScopeNavigation.move(to: 1, offset: -10, from: ScopeRequest()).request.offset == 0)
    }

    @Test func goingUpNeedsAScopeBelowTheTopLevel() {
        #expect(!canGoUp(.ready, 5, nil, live: false, snapshot: false))
        #expect(!canGoUp(.settled, 0, 0, live: false, snapshot: false))
        #expect(!canGoUp(.settled, nil, nil, live: false, snapshot: false))
        #expect(canGoUp(.settled, 5, 0, live: false, snapshot: false))
        #expect(canGoUp(.settled, 0, nil, live: false, snapshot: false))
    }

    @Test func goingUpWhileScanningWaitsForTheSnapshotThatNamesTheParent() {
        #expect(!canGoUp(.scanning, 5, 0, live: true, snapshot: false))
        #expect(canGoUp(.scanning, 5, 0, live: true, snapshot: true))
    }

    @Test func onlyReadFoldersAndPackagesOpen() {
        func node(_ kind: NodeKind, _ issue: CoverageIssue? = nil) -> ScanNode {
            ScanNode(id: 1, parent: 0, name: "x", kind: kind, issue: issue, device: 1, inode: 1)
        }
        #expect(ScopeNavigation.canOpen(node(.directory)))
        #expect(ScopeNavigation.canOpen(node(.package)))
        #expect(ScopeNavigation.canOpen(node(.directory, .denied)))
        #expect(!ScopeNavigation.canOpen(node(.directory, .policyExcluded)))
        #expect(!ScopeNavigation.canOpen(node(.directory, .volumeBoundary)))
        #expect(!ScopeNavigation.canOpen(node(.file)))
        #expect(!ScopeNavigation.canOpen(node(.symbolicLink)))
        #expect(!ScopeNavigation.canOpen(node(.other)))
    }

    @Test func listedAncestorIsTheChildOfTheScopeOnThePath() {
        // 0 ← 1 ← 2 ← 3, and 9 outside the tree.
        let parents: [Int: Int] = [1: 0, 2: 1, 3: 2]
        let parentOf: (Int) -> Int? = { parents[$0] }
        #expect(ScopeNavigation.listedAncestor(of: 3, under: 0, parentOf: parentOf) == 1)
        #expect(ScopeNavigation.listedAncestor(of: 1, under: 0, parentOf: parentOf) == 1)
        #expect(ScopeNavigation.listedAncestor(of: 3, under: 2, parentOf: parentOf) == 3)
        #expect(ScopeNavigation.listedAncestor(of: 0, under: nil, parentOf: parentOf) == 0)
        #expect(ScopeNavigation.listedAncestor(of: 3, under: 7, parentOf: parentOf) == nil)
        #expect(ScopeNavigation.listedAncestor(of: 9, under: 0, parentOf: parentOf) == nil)
    }

    @Test func listedAncestorGivesUpOnACycle() {
        let parentOf: (Int) -> Int? = { $0 == 1 ? 2 : 1 }
        #expect(ScopeNavigation.listedAncestor(of: 1, under: 0, parentOf: parentOf) == nil)
    }
}

@Suite struct LivePageTests {
    let size = ScopeSnapshot.pageSize

    @Test func oneShortPageIsNotPaged() {
        let page = LivePage(offset: 0, shown: 10, discovered: 10)
        #expect(!page.isPaged)
        #expect(!page.hasPrevious)
        #expect(!page.hasNext)
    }

    @Test func aFullFirstPageOfMoreHasANextPage() {
        let page = LivePage(offset: 0, shown: size, discovered: size + 1)
        #expect(page.isPaged)
        #expect(!page.hasPrevious)
        #expect(page.hasNext)
        #expect(page.nextOffset == size)
    }

    @Test func exactlyOnePageIsNotPaged() {
        let page = LivePage(offset: 0, shown: size, discovered: size)
        #expect(!page.isPaged)
        #expect(!page.hasNext)
    }

    @Test func theLastPageHasOnlyAPreviousPage() {
        let page = LivePage(offset: size, shown: 3, discovered: size + 3)
        #expect(page.isPaged)
        #expect(page.hasPrevious)
        #expect(!page.hasNext)
        #expect(page.previousOffset == 0)
    }

    @Test func previousOffsetNeverGoesBelowZero() {
        #expect(LivePage(offset: 10, shown: 0, discovered: 0).previousOffset == 0)
        #expect(LivePage(offset: 3 * size, shown: 0, discovered: 0).previousOffset == 2 * size)
    }

    @Test func aTurnedPageStaysPagedBeforeItsRowsArrive() {
        let page = LivePage(offset: size, shown: 0, discovered: 0)
        #expect(page.isPaged)
        #expect(page.hasPrevious)
        #expect(!page.hasNext)
    }

    @Test func theSnapshotSuppliesItsOwnPage() {
        let snapshot = PresentationFixtures.scenario(.scanning).snapshot
        let page = LivePage(snapshot)
        #expect(page.offset == snapshot.request.offset)
        #expect(page.shown == snapshot.rows.count)
        #expect(page.discovered == snapshot.discoveredChildren)
    }
}
