import Foundation
import SpacewiseAppModel
import SpacewiseCore

/// What the session needs from the window while it runs: a redraw, the selection cleared, announcements, and
/// whether the person is engaged with the map (a live map update waits while they are).
@MainActor protocol ScanSessionDelegate: AnyObject {
    /// Show the session's current state.
    func sessionNeedsRender()
    /// The selection and the inspector's notice no longer apply.
    func sessionClearsSelection()
    func sessionClearsNotice()
    /// The person hovers the map or has something selected.
    var sessionMapIsEngaged: Bool { get }
    /// A scan request is about to check its location; the window must be visible for it.
    func sessionScanWillStart()
    /// A scan could not admit a root and the previous screen is still available.
    func sessionScanWasRefused(_ result: ScanResult, plan: ScanPlan)
    /// The scan task ended, including refusals or cancellation during validation.
    func sessionScanDidSettle()
    func sessionAnnounce(_ text: String)
}

/// Runs one scan at a time and holds what the window shows: the result or the live snapshot, the scope being viewed,
/// and the storage map model. Every change ends in `sessionNeedsRender()`.
@MainActor final class ScanSession {
    weak var delegate: ScanSessionDelegate?

    // Scan
    var scanTask: Task<Void, Never>?
    var result: ScanResult?
    var activeScanID: UUID?
    private var validatingScanID: UUID?
    var lastPlan: ScanPlan?
    var stopping = false
    var liveProgress: ScanProgress?
    /// True for a moment after a scan finishes; see `StatusArea.confirmationSeconds`.
    var confirmsCompletion = false
    private var confirmationTask: Task<Void, Never>?
    // Scope
    var topLevel: Int?
    var scopeTitle = ProductCopy.Scope.startupDisk
    var isFolderScope = false
    var scopeRequest = ScopeRequest()
    var scopeSnapshot: ScopeSnapshot?
    var scopeRevision: UInt64 = 0
    var liveSource: SnapshotRows?
    var settledSource: SettledRows?
    private(set) var rowRankingTask: Task<Void, Never>?
    // Storage map: the displayed model, a held-back live update, and the off-main settled build.
    var treemapModel: TreemapModel?
    var treemapRevision = 0
    var pendingLiveTreemap: TreemapModel?
    var treemapTask: Task<Void, Never>?
    /// The time results are aged against.
    var now: Date { Date() }

    var isLive: Bool { scanTask != nil }

    var isScanning: Bool { isLive && validatingScanID == nil }
    var isValidating: Bool { validatingScanID != nil }

    var phase: ScanPhase {
        if isScanning { return stopping ? .stopping : .scanning }
        return result == nil ? .ready : .settled
    }

    private func render() { delegate?.sessionNeedsRender() }

    // MARK: Scanning (explicit user actions only)

    func start(_ plan: ScanPlan) {
        guard scanTask == nil else { return }
        let scanID = UUID()
        validatingScanID = scanID
        scanTask = Task {
            let value = await Scanner.scan(
                plan: plan, scanID: scanID,
                rootAccepted: { [weak self] in await self?.beginAcceptedScan(plan, id: scanID) },
                scopeRequest: { [weak self] in await self?.scopeRequest ?? ScopeRequest() },
                scopeUpdate: { [weak self] snapshot in await self?.receiveScope(snapshot) },
                update: { [weak self] progress in await self?.receiveProgress(progress, id: scanID) })
            if validatingScanID == scanID {
                let refused = !stopping && value.progress.state == .invalid
                validatingScanID = nil
                scanTask = nil
                stopping = false
                render()
                if refused { delegate?.sessionScanWasRefused(value, plan: plan) }
                delegate?.sessionScanDidSettle()
            } else if activeScanID == scanID {
                settle(value)
            }
        }
        delegate?.sessionScanWillStart()
        render()
    }

    private func beginAcceptedScan(_ plan: ScanPlan, id: UUID) {
        guard validatingScanID == id, !stopping, !Task.isCancelled else { return }
        validatingScanID = nil
        lastPlan = plan
        endCompletionConfirmation()
        isFolderScope = !plan.startup
        topLevel = plan.startup ? nil : 0
        scopeTitle = plan.startup ? ProductCopy.Scope.startupDisk : Self.folderTitle(plan)
        activeScanID = id
        scopeRequest = ScopeRequest(parent: topLevel, wantsTreemap: true)
        scopeSnapshot = nil
        liveSource = nil
        clearSettledRows()
        treemapTask?.cancel()
        setTreemap(nil)
        pendingLiveTreemap = nil
        delegate?.sessionClearsSelection()
        scopeRevision = 0
        liveProgress = nil
        stopping = false
        result = nil
        render()
        delegate?.sessionAnnounce(ProductCopy.Announcement.scanning(scopeTitle))
    }

    private static func folderTitle(_ plan: ScanPlan) -> String {
        plan.roots.first.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent }
            ?? ProductCopy.Scope.folder
    }

    /// The scanner returned: its result replaces the live state.
    func settle(_ scanResult: ScanResult) {
        var value = scanResult
        // Stop and settlement run on the main actor. A Stop accepted while the worker's result is in transit
        // still wins; an already built namespace can be retained with that result.
        if stopping { value.progress.state = .cancelled }
        let parent = value.settledScope(for: currentParent)
        let resetView = value.progress.cancelled || parent != currentParent
        scopeRequest = ScopeNavigation.move(to: parent, from: scopeRequest).request
        topLevel = lastPlan?.startup == true ? nil : value.settledScope(for: topLevel)
        result = value
        scopeSnapshot = nil
        liveSource = nil
        clearSettledRows()
        activeScanID = nil
        scanTask = nil
        stopping = false
        pendingLiveTreemap = nil
        if resetView {
            setTreemap(nil)
            delegate?.sessionClearsSelection()
            delegate?.sessionClearsNotice()
        }
        rebuildSettledTreemap()
        confirmCompletion()
        render()
        let outcome = StatusPresentation.outcome(
            phase: .settled, progress: value.progress, scopeName: scopeTitle,
            coverage: value.coverage)
        delegate?.sessionAnnounce(outcome?.title ?? ProductCopy.Announcement.finished)
        delegate?.sessionScanDidSettle()
    }

    /// Shows the brief "Scan complete" line, then lets it go. A scan with limits keeps its own line regardless.
    private func confirmCompletion() {
        confirmationTask?.cancel()
        confirmsCompletion = true
        confirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(StatusArea.confirmationSeconds))
            guard !Task.isCancelled, let self else { return }
            self.endCompletionConfirmation()
            self.render()
        }
    }

    func endCompletionConfirmation() {
        confirmationTask?.cancel()
        confirmationTask = nil
        confirmsCompletion = false
    }

    private func receiveProgress(_ progress: ScanProgress, id: UUID) {
        guard activeScanID == id, !stopping, !progress.finished else { return }
        liveProgress = progress
    }

    /// Stop was requested: keep what was found and cancel the scanner.
    func stop() {
        guard let scanTask, !stopping else { return }
        stopping = true
        scanTask.cancel()
        render()
        delegate?.sessionAnnounce(ProductCopy.Announcement.stopping)
    }

    // MARK: Progressive scope updates

    private func receiveScope(_ snapshot: ScopeSnapshot) {
        guard !stopping, snapshot.provisional, let activeScanID,
            snapshot.isCurrent(scanID: activeScanID, request: scopeRequest, after: scopeRevision)
        else {
            return
        }
        scopeRevision = snapshot.revision
        scopeSnapshot = snapshot
        liveSource = SnapshotRows(snapshot)
        liveProgress = snapshot.progress
        if let map = snapshot.treemap { receiveLiveTreemap(map) }
        render()
    }

    // MARK: Navigation

    var currentParent: Int? { scopeRequest.parent }

    var canGoUp: Bool {
        ScopeNavigation.canGoUp(
            phase: phase, currentParent: currentParent, topLevel: topLevel, isLive: isScanning,
            hasLiveSnapshot: scopeSnapshot != nil)
    }

    /// The live page as the current request sees it; nil until a snapshot for the scope has arrived.
    var requestedPage: LivePage? {
        scopeSnapshot.map {
            LivePage(offset: scopeRequest.offset, shown: $0.rows.count, discovered: $0.discoveredChildren)
        }
    }

    func navigate(to id: Int?, offset: Int = 0) {
        let move = ScopeNavigation.move(to: id, offset: offset, from: scopeRequest)
        scopeRequest = move.request
        if isScanning {
            scopeSnapshot = nil
            liveSource = nil
        } else {
            clearSettledRows()
        }
        // A new scope clears the selection so no action can apply to something no longer visible.
        if move.changesScope {
            delegate?.sessionClearsSelection()
            pendingLiveTreemap = nil
        }
        delegate?.sessionClearsNotice()
        if !isScanning {
            if move.changesScope {
                treemapTask?.cancel()
                setTreemap(nil)
                rebuildSettledTreemap()
            }
        } else if move.changesScope {
            setTreemap(nil)
        }
        render()
    }

    func goToTopLevel() {
        guard phase != .ready else { return }
        navigate(to: topLevel)
    }

    func goUp() {
        guard canGoUp else { return }
        if isScanning {
            guard let snapshot = scopeSnapshot else { return }
            navigate(to: snapshot.parentOfScope)
        } else {
            navigate(to: result?.logicalParent(of: currentParent ?? -1))
        }
    }

    func previousPage() {
        let page = LivePage(offset: scopeRequest.offset, shown: 0, discovered: 0)
        guard isLive, page.hasPrevious else { return }
        navigate(to: currentParent, offset: page.previousOffset)
    }

    func nextPage() {
        guard isLive, let page = requestedPage, page.hasNext else { return }
        navigate(to: currentParent, offset: page.nextOffset)
    }

    // MARK: Rows and paths

    func displayPath(for id: Int) -> String? { result?.displayPath(for: id) }

    /// The settled rows for the current scope, built once per result and scope.
    func settledRows() -> SettledRows? {
        guard let result else { return nil }
        if let settledSource, settledSource.result.id == result.id { return settledSource }
        let parent = currentParent
        if result.needsBackgroundRowSort(parent: parent) {
            if rowRankingTask == nil {
                let request = scopeRequest
                rowRankingTask = Task { [weak self] in
                    guard let ids = try? await result.orderedChildIDs(of: parent), !Task.isCancelled,
                        let self, self.result?.id == result.id, self.scopeRequest == request
                    else { return }
                    self.rowRankingTask = nil
                    self.settledSource = SettledRows(result: result, ids: ids)
                    self.render()
                }
            }
            return nil
        }
        settledSource = SettledRows(result: result, parent: parent)
        return settledSource
    }

    private func clearSettledRows() {
        rowRankingTask?.cancel()
        rowRankingTask = nil
        settledSource = nil
    }

    /// Any scan node as a row: settled results use the index, live scans the map's own rows.
    func rowForNode(_ id: Int) -> ScopeRow? {
        if !isScanning { return result?.logicalRow(for: id) }
        return treemapModel?.tileIndex(forNode: id).flatMap { treemapModel?.rows[$0] }
    }

    func parentOfNode(_ id: Int) -> Int? {
        if !isScanning { return result?.logicalParent(of: id) }
        // Live rows carry physical parents; the logical parent is where the map or the list shows the item.
        if let model = treemapModel, let tile = model.tileIndex(forNode: id) {
            let parent = model.tiles[tile].parent
            return parent <= 0 ? model.scope : model.tiles[parent].nodeID
        }
        return liveSource?.snapshot.rows.contains { $0.node.id == id } == true ? currentParent : nil
    }

    /// The facts the screen is built from, now.
    func screenInputs(volume: VolumeContext?) -> ScreenInputs {
        let phase = self.phase
        let settled = phase == .settled ? settledRows() : nil
        return ScreenInputs(
            phase: phase, scopeTitle: scopeTitle, isFolderScope: isFolderScope, volume: volume, now: now,
            liveProgress: liveProgress, liveSnapshot: scopeSnapshot, liveSource: liveSource,
            requestOffset: scopeRequest.offset, result: result, settledSource: settled,
            currentParent: currentParent, treemapModel: treemapModel, treemapRevision: treemapRevision,
            hasPendingTreemap: pendingLiveTreemap != nil, canGoUp: canGoUp, isLive: isScanning,
            confirmsCompletion: confirmsCompletion)
    }

    // MARK: Storage map model

    func setTreemap(_ model: TreemapModel?) {
        treemapModel = model
        treemapRevision += 1
    }

    /// A live map arrives about once a second. While the person hovers or has a selection it is held back so tiles
    /// do not move under the pointer; the "Update Map" chip applies it.
    func receiveLiveTreemap(_ map: TreemapModel) {
        if treemapModel != nil, delegate?.sessionMapIsEngaged == true {
            pendingLiveTreemap = map
            return
        }
        pendingLiveTreemap = nil
        setTreemap(map)
    }

    func applyPendingTreemap() {
        guard let map = pendingLiveTreemap else { return }
        pendingLiveTreemap = nil
        setTreemap(map)
        render()
    }

    func treemapEngagementMayHaveEnded() {
        guard pendingLiveTreemap != nil, delegate?.sessionMapIsEngaged != true else { return }
        applyPendingTreemap()
    }

    /// Settled maps are built off the main actor from the immutable result; stale builds are dropped.
    func rebuildSettledTreemap() {
        treemapTask?.cancel()
        guard !isScanning, let result else { return }
        let parent = currentParent
        let id = result.id
        treemapTask = Task { [weak self] in
            let model = await TreemapBuilder.build(result: result, parent: parent)
            guard !Task.isCancelled, let self, self.result?.id == id, self.currentParent == parent, !self.isScanning
            else {
                return
            }
            self.treemapTask = nil
            self.setTreemap(model)
            self.render()
        }
    }
}
