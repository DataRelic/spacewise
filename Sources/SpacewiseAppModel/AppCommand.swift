import SpacewiseCore

/// The commands the menu bar and the toolbar share. Both ask `CommandState.isEnabled`, so they cannot disagree.
public enum AppCommand: Sendable, CaseIterable {
    case scanInternal, scanFolder, rescan, stopScan
    case showInFinder, openItem, quickLook
    case filterList
    case toggleInspector, toggleList, resetSplit, showScanDetails
    case enclosingFolder, openFolder, topLevel, previousPage, nextPage
}

/// The facts command availability depends on, read from the session and the selection at one moment.
public struct CommandState: Sendable, Equatable {
    public var phase: ScanPhase
    /// A scan is running.
    public var isLive: Bool
    public var isStopping: Bool
    /// A scan plan exists to repeat.
    public var hasLastPlan: Bool
    public var hasResult: Bool
    /// The selection has a location that can be copied or shown in Finder.
    public var selectionHasLocation: Bool
    /// The selection is a folder or package that can be opened.
    public var selectionCanOpen: Bool
    public var canGoUp: Bool
    /// What Open would do with the selection (see `ItemOpenRule`).
    public var selectionOpen: OpenBehavior
    /// The selection can be previewed with Quick Look.
    public var selectionCanQuickLook: Bool
    /// The live page: where the request starts, and whether a further page is known to exist.
    public var pageOffset: Int
    public var hasNextPage: Bool

    public init(
        phase: ScanPhase, isLive: Bool, isStopping: Bool, hasLastPlan: Bool, hasResult: Bool,
        selectionHasLocation: Bool, selectionCanOpen: Bool, canGoUp: Bool, pageOffset: Int, hasNextPage: Bool,
        selectionOpen: OpenBehavior = .unavailable, selectionCanQuickLook: Bool = false
    ) {
        self.phase = phase
        self.isLive = isLive
        self.isStopping = isStopping
        self.hasLastPlan = hasLastPlan
        self.hasResult = hasResult
        self.selectionHasLocation = selectionHasLocation
        self.selectionCanOpen = selectionCanOpen
        self.canGoUp = canGoUp
        self.pageOffset = pageOffset
        self.hasNextPage = hasNextPage
        self.selectionOpen = selectionOpen
        self.selectionCanQuickLook = selectionCanQuickLook
    }

    /// Scan details describe a settled result only.
    public var canShowScanDetails: Bool { hasResult && !isLive }

    public func isEnabled(_ command: AppCommand) -> Bool {
        switch command {
        case .scanInternal, .scanFolder: !isLive
        case .rescan: !isLive && hasLastPlan && hasResult
        case .stopScan: isLive && !isStopping
        case .showInFinder: selectionHasLocation
        case .openItem: selectionHasLocation && selectionOpen == .open
        case .quickLook: selectionHasLocation && selectionCanQuickLook
        case .filterList: phase != .ready
        case .toggleInspector, .toggleList, .resetSplit: phase != .ready
        case .showScanDetails: canShowScanDetails
        case .enclosingFolder, .topLevel: canGoUp
        case .openFolder: phase != .ready && selectionCanOpen
        case .previousPage: isLive && pageOffset > 0
        case .nextPage: isLive && hasNextPage
        }
    }
}
