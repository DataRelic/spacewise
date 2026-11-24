import SpacewiseCore

/// Where navigation goes, and whether it can. The session applies the result; nothing here touches the screen.
public enum ScopeNavigation {
    /// A scope request and whether it leaves the current folder (a page change stays in it).
    public struct Move: Sendable, Equatable {
        public let request: ScopeRequest
        public let changesScope: Bool
    }

    /// The request that shows `parent` from `offset`, replacing `current`. Every move asks for a fresh storage map.
    public static func move(to parent: Int?, offset: Int = 0, from current: ScopeRequest) -> Move {
        let request = ScopeRequest(
            parent: parent, offset: offset, generation: current.generation + 1, wantsTreemap: true)
        return Move(request: request, changesScope: parent != current.parent)
    }

    /// Up is possible below the top level. While scanning it needs the live snapshot, which names the scope's parent.
    public static func canGoUp(
        phase: ScanPhase, currentParent: Int?, topLevel: Int?, isLive: Bool,
        hasLiveSnapshot: Bool
    ) -> Bool {
        guard phase != .ready, currentParent != topLevel else { return false }
        return isLive ? hasLiveSnapshot : true
    }

    /// Folders and packages open, except ones left out by policy or on another volume (their contents were not read).
    public static func canOpen(_ node: ScanNode) -> Bool {
        (node.kind == .directory || node.kind == .package)
            && node.issue != .policyExcluded
            && node.issue != .volumeBoundary
    }

    /// The listed row that stands for `node`: the ancestor (or the node itself) directly under `scope`. Nil when the
    /// node is not under the scope, or the walk does not reach it within 100,000 steps.
    public static func listedAncestor(of node: Int, under scope: Int?, parentOf: (Int) -> Int?) -> Int? {
        var cursor = node
        for _ in 0..<100_000 {
            if parentOf(cursor) == scope { return cursor }
            guard let parent = parentOf(cursor) else { return nil }
            cursor = parent
        }
        return nil
    }
}

/// One page of a live scope: rows arrive in discovery order, `ScopeSnapshot.pageSize` at a time.
public struct LivePage: Sendable, Equatable {
    public let offset: Int
    public let shown: Int
    public let discovered: Int

    public init(offset: Int, shown: Int, discovered: Int) {
        self.offset = offset
        self.shown = shown
        self.discovered = discovered
    }

    /// The page a live snapshot carries.
    public init(_ snapshot: ScopeSnapshot) {
        self.init(offset: snapshot.request.offset, shown: snapshot.rows.count, discovered: snapshot.discoveredChildren)
    }

    /// Paging controls show once there is more than one page, or the person has already paged.
    public var isPaged: Bool { discovered > ScopeSnapshot.pageSize || offset > 0 }
    public var hasPrevious: Bool { offset > 0 }
    public var hasNext: Bool { offset + shown < discovered }
    public var previousOffset: Int { max(0, offset - ScopeSnapshot.pageSize) }
    public var nextOffset: Int { offset + ScopeSnapshot.pageSize }
}
