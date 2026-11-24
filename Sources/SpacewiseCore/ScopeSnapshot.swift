import Foundation

public struct ScopeRequest: Sendable, Equatable {
    public let parent: Int?
    public let offset: Int
    public let generation: UInt64
    /// Ask the scanner to also attach a bounded storage-map model (throttled to about once a second).
    public let wantsTreemap: Bool
    public init(parent: Int? = nil, offset: Int = 0, generation: UInt64 = 0, wantsTreemap: Bool = false) {
        self.parent = parent
        self.offset = max(0, offset)
        self.generation = generation
        self.wantsTreemap = wantsTreemap
    }
}
public struct ScopeRow: Sendable {
    public let node: ScanNode
    public let classification: ContentClassification
    public let coverage: NodeCoverageStatus
    public let enumeration: DirectoryEnumeration?
    /// Provisional (scanning) rows are always inspection-only.
    public let eligibility: OperationEligibility
    public init(
        node: ScanNode, classification: ContentClassification, coverage: NodeCoverageStatus,
        enumeration: DirectoryEnumeration?, eligibility: OperationEligibility = .inspectionOnly
    ) {
        self.node = node
        self.classification = classification
        self.coverage = coverage
        self.enumeration = enumeration
        self.eligibility = eligibility
    }
}
/// One breadcrumb segment. IDs are valid only within the scan that produced them.
public struct ScopeCrumb: Sendable, Equatable {
    public let id: Int
    public let name: String
}
/// The folder being inspected: its ancestry and its own totals. Provisional while scanning.
public struct ScopeSummary: Sendable {
    /// Ancestors from the scan root down to the scope itself. Empty for the top-level root list.
    public let crumbs: [ScopeCrumb]
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64
    /// True when some contents are unmeasured or still being read, so the totals are lower bounds.
    public let allocationUnknown: Bool
    /// The scope folder's own coverage issue and enumeration state (nil for the root list).
    public let issue: CoverageIssue?
    public let enumeration: DirectoryEnumeration?
    public var parent: Int? { crumbs.last?.id }
    public var parentOfScope: Int? { crumbs.count >= 2 ? crumbs[crumbs.count - 2].id : nil }
}
public struct ScopeSnapshot: Sendable {
    public static let pageSize = 256
    public let scanID: UUID
    public let revision: UInt64
    public let request: ScopeRequest
    public let parentOfScope: Int?
    public let scope: ScopeSummary
    public let rows: [ScopeRow]
    public let discoveredChildren: Int
    public let enumeration: DirectoryEnumeration?
    public let provisional: Bool
    public let progress: ScanProgress
    /// Provisional storage map for `request.parent`, present only when requested and not throttled.
    public let treemap: TreemapModel?
    public func isCurrent(scanID: UUID, request: ScopeRequest, after revision: UInt64) -> Bool {
        self.scanID == scanID && self.request == request && self.revision > revision
    }
}

extension ScanResult {
    /// Terminal snapshots use the same topology and totals as the returned result. Remapping a scope also resets its
    /// page, so the consumer sees the replacement location from the start.
    func terminalSnapshot(request: ScopeRequest, revision: UInt64) -> ScopeSnapshot {
        let parent = settledScope(for: request.parent)
        let answered =
            parent == request.parent
            ? request
            : ScopeRequest(
                parent: parent, generation: request.generation, wantsTreemap: request.wantsTreemap)
        let ids = childIDs(of: parent)
        let page = namespace.page(for: parent, offset: answered.offset, limit: ScopeSnapshot.pageSize)
        let rows = (page?.ids ?? Array(ids.dropFirst(answered.offset).prefix(ScopeSnapshot.pageSize)))
            .compactMap(logicalRow(for:))
        let summary = logicalSummary(parent: parent)
        return ScopeSnapshot(
            scanID: id, revision: revision, request: answered, parentOfScope: summary.parentOfScope,
            scope: summary, rows: rows, discoveredChildren: page?.total ?? ids.count,
            enumeration: summary.enumeration, provisional: false, progress: progress, treemap: nil)
    }
}
