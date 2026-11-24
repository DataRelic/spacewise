import Synchronization

@testable import SpacewiseCore

/// Tallies the work a `ProgressiveIndex` reports. Copies of an index share their counter, as they share the
/// observer reference.
final class IndexWorkCounter: ProgressiveIndexObserver {
    struct Totals: Sendable {
        var rootSummaryVisits = 0
        var namespaceBuilds = 0
        var namespaceBuildNodes = 0
        var namespaceAppendWork = 0
        /// Work of the current namespace builder. A new build starts these at zero, as the builder's own counters did.
        var namespaceVisits = 0
        var namespaceReconciles = 0
        var namespaceSettles = 0
    }
    private let totals = Mutex(Totals())
    var current: Totals { totals.withLock { $0 } }

    func indexDidWork(_ work: ProgressiveIndexWork) {
        totals.withLock { totals in
            switch work {
            case .rootSummary(let visits): totals.rootSummaryVisits += visits
            case .namespaceBuild(let nodes):
                totals.namespaceBuilds += 1
                totals.namespaceBuildNodes += nodes
                totals.namespaceVisits = 0
                totals.namespaceReconciles = 0
                totals.namespaceSettles = 0
            case .namespaceAppend(let nodes): totals.namespaceAppendWork += nodes
            case .namespaceVisit: totals.namespaceVisits += 1
            case .namespaceReconcile: totals.namespaceReconciles += 1
            case .namespaceSettle: totals.namespaceSettles += 1
            }
        }
    }
}

extension ProgressiveIndex {
    /// A fresh index that counts its work. Reading the counters below from any other index is a test bug.
    static func counted() -> ProgressiveIndex {
        var index = ProgressiveIndex()
        index.observer = IndexWorkCounter()
        return index
    }
    private var counter: IndexWorkCounter {
        guard let counter = observer as? IndexWorkCounter else {
            preconditionFailure("Work counters are only recorded for an index made with ProgressiveIndex.counted()")
        }
        return counter
    }
    var rootSummaryVisitCount: Int { counter.current.rootSummaryVisits }
    /// Full constructions of the namespace (the first, plus any explicit invalidation or root-path change).
    var namespaceBuildCount: Int { counter.current.namespaceBuilds }
    var namespaceBuildNodeCount: Int { counter.current.namespaceBuildNodes }
    /// Nodes admitted incrementally after construction.
    var namespaceAppendWorkCount: Int { counter.current.namespaceAppendWork }
    /// Child entries the current builder admitted to name groups, including bootstrap of newly merged folders.
    var namespaceVisitCount: Int { counter.current.namespaceVisits }
    var namespaceReconcileCount: Int { counter.current.namespaceReconciles }
    /// Recomputations of the managed aggregate from finalized nodes (once per settled scan, never per query).
    var namespaceSettleCount: Int { counter.current.namespaceSettles }
}
