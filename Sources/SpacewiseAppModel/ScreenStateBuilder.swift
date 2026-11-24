import Foundation
import SpacewiseCore

/// The session facts one screen is built from.
public struct ScreenInputs {
    public var phase: ScanPhase
    public var scopeTitle: String
    public var isFolderScope: Bool
    public var volume: VolumeContext?
    public var now: Date
    public var liveProgress: ScanProgress?
    public var liveSnapshot: ScopeSnapshot?
    public var liveSource: SnapshotRows?
    /// The current request's offset. Right after a page request it is ahead of the last snapshot.
    public var requestOffset: Int
    public var result: ScanResult?
    /// The settled rows for the current scope. Nil while a folder is being ordered.
    public var settledSource: SettledRows?
    public var currentParent: Int?
    public var treemapModel: TreemapModel?
    public var treemapRevision: Int
    public var hasPendingTreemap: Bool
    public var canGoUp: Bool
    public var isLive: Bool
    /// True for a moment after a scan finishes, so a scan with nothing wrong gets a brief confirmation.
    public var confirmsCompletion: Bool

    public init(
        phase: ScanPhase, scopeTitle: String, isFolderScope: Bool, volume: VolumeContext?, now: Date,
        liveProgress: ScanProgress?, liveSnapshot: ScopeSnapshot?, liveSource: SnapshotRows?, requestOffset: Int,
        result: ScanResult?, settledSource: SettledRows?, currentParent: Int?, treemapModel: TreemapModel?,
        treemapRevision: Int, hasPendingTreemap: Bool, canGoUp: Bool, isLive: Bool,
        confirmsCompletion: Bool = false
    ) {
        self.phase = phase
        self.scopeTitle = scopeTitle
        self.isFolderScope = isFolderScope
        self.volume = volume
        self.now = now
        self.liveProgress = liveProgress
        self.liveSnapshot = liveSnapshot
        self.liveSource = liveSource
        self.requestOffset = requestOffset
        self.result = result
        self.settledSource = settledSource
        self.currentParent = currentParent
        self.treemapModel = treemapModel
        self.treemapRevision = treemapRevision
        self.hasPendingTreemap = hasPendingTreemap
        self.canGoUp = canGoUp
        self.isLive = isLive
        self.confirmsCompletion = confirmsCompletion
    }
}

/// One built screen: the main view's state and the window's title and subtitle.
public struct Screen {
    public var state: ScreenState
    public var windowTitle: String
    public var windowSubtitle: String
}

/// Turns session facts into what the window shows. The caller adds the closures that reach back into the session.
public enum ScreenStateBuilder {
    @MainActor public static func build(_ inputs: ScreenInputs) -> Screen {
        var state = ScreenState()
        let phase = inputs.phase
        state.phase = phase
        state.scopeTitle = inputs.scopeTitle
        state.isFolderScope = inputs.isFolderScope
        state.volume = inputs.volume
        var subtitleProgress = inputs.liveProgress
        var ended: Date?
        switch phase {
        case .ready:
            break
        case .scanning, .stopping:
            state.provisional = true
            let progress = inputs.liveProgress ?? ScanProgress()
            state.status = StatusArea.make(
                phase: phase, progress: progress, scopeName: inputs.scopeTitle,
                coverage: nil, age: nil, confirmsCompletion: false)
            if let snapshot = inputs.liveSnapshot, let source = inputs.liveSource {
                state.source = source
                state.summary = snapshot.scope
                state.total = snapshot.discoveredChildren
                state.livePage = LivePage(snapshot)
                state.empty = EmptyScope.make(
                    scopeName: snapshot.scope.crumbs.last?.name ?? inputs.scopeTitle,
                    enumeration: snapshot.scope.enumeration, issue: snapshot.scope.issue,
                    state: .scanning, provisional: true)
            } else {
                // Before the first snapshot for this request: only a page already turned can be turned back.
                state.livePage = LivePage(offset: inputs.requestOffset, shown: 0, discovered: 0)
                state.empty = EmptyScope(
                    symbol: "clock", title: ProductCopy.Waiting.title,
                    detail: ProductCopy.Waiting.detail)
            }
        case .settled:
            let source = inputs.settledSource
            guard let result = inputs.result,
                source != nil || result.needsBackgroundRowSort(parent: inputs.currentParent)
            else { break }
            let summary = result.logicalSummary(parent: inputs.currentParent)
            state.source = source
            state.summary = summary
            state.total = source?.count ?? result.logicalChildCount(of: inputs.currentParent)
            state.status = StatusArea.make(
                phase: .settled, progress: result.progress, scopeName: inputs.scopeTitle,
                coverage: result.coverage, age: inputs.now.timeIntervalSince(result.ended),
                confirmsCompletion: inputs.confirmsCompletion)
            if source == nil {
                state.isPreparingRows = true
                state.empty = EmptyScope(
                    symbol: "arrow.up.arrow.down", title: ProductCopy.Waiting.orderingTitle,
                    detail: ProductCopy.Waiting.orderingDetail)
            } else {
                state.empty = EmptyScope.make(
                    scopeName: summary.crumbs.last?.name ?? inputs.scopeTitle,
                    enumeration: summary.enumeration, issue: summary.issue,
                    state: result.progress.state, provisional: false)
            }
            subtitleProgress = result.progress
            ended = result.ended
        }
        if phase != .ready {
            state.treemap = TreemapScreen(
                model: inputs.treemapModel, revision: inputs.treemapRevision,
                pendingUpdate: inputs.hasPendingTreemap, canZoomOut: inputs.canGoUp,
                message: MapMessage.make(
                    phase: phase, model: inputs.treemapModel,
                    isLive: inputs.isLive))
        }
        let title = phase == .ready ? ProductCopy.App.name : inputs.scopeTitle
        let subtitle = StatusPresentation.subtitle(
            phase: phase, progress: subtitleProgress, ended: ended, now: inputs.now)
        return Screen(state: state, windowTitle: title, windowSubtitle: subtitle)
    }
}
