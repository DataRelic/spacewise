import SpacewiseCore

/// Everything the main window shows for one moment of the session. Built by `ScreenStateBuilder`, drawn by the app's
/// main view controller; it holds no AppKit types.
public struct ScreenState {
    public var phase: ScanPhase = .ready
    public var scopeTitle = ProductCopy.Scope.startupDisk
    public var isFolderScope = false
    public var source: RowSource?
    public var isPreparingRows = false
    public var isFiltering = false
    public var summary: ScopeSummary?
    public var provisional = false
    public var offset: Int { livePage?.offset ?? 0 }
    /// Direct entries in the scope, before any filter and across all discovered pages.
    public var total = 0
    /// The one status line above the map, chosen by `StatusArea`.
    public var status: Banner?
    public var empty: EmptyScope?
    public var volume: VolumeContext?
    public var livePage: LivePage?
    public var canPage: Bool { livePage?.isPaged == true }
    public var canGoPrevious: Bool { livePage?.hasPrevious == true }
    public var canGoNext: Bool { livePage?.hasNext == true }
    public var inspect: ((ScopeRow, RowPresentation) -> InspectorContent)?
    public var treemap: TreemapScreen?
    /// Resolves any scan node (not only listed rows) to a row; settled results use the index, live scans the map's own rows.
    public var rowForNode: ((Int) -> ScopeRow?)?
    public var parentOf: ((Int) -> Int?)?
    public var pathFor: ((Int) -> String?)?
    /// The number of entries directly inside a folder, for the list's Items column; nil when not known.
    public var itemCount: ((Int) -> Int?)?

    public init() {}
}

/// What the storage map panel should show. `revision` changes only when the model does, so ordinary re-renders are free.
public struct TreemapScreen {
    public var model: TreemapModel?
    public var revision = 0
    public var pendingUpdate = false
    public var canZoomOut = false
    public var message: EmptyScope?

    public init(
        model: TreemapModel?, revision: Int = 0, pendingUpdate: Bool = false, canZoomOut: Bool = false,
        message: EmptyScope? = nil
    ) {
        self.model = model
        self.revision = revision
        self.pendingUpdate = pendingUpdate
        self.canZoomOut = canZoomOut
        self.message = message
    }
}
