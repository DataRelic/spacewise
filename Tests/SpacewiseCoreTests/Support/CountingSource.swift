import Foundation

@testable import SpacewiseCore

/// Counts every read a source performs, for ledger assertions.
final class WorkCounter: @unchecked Sendable {
    var weights = 0, rows = 0, infos = 0, selected = 0, sampled = 0
    var total: Int { weights + rows + infos + selected + sampled }
}
struct CountingSource<Base: TreemapSource>: TreemapSource {
    let base: Base
    let counter = WorkCounter()
    var managedZones: Bool { base.managedZones }
    var rootWeight: UInt64 { base.rootWeight }
    func selectionCost(of parent: Int?) -> Int { base.selectionCost(of: parent) }
    func selectionCost(of parent: Int?, limit: Int) -> Int { base.selectionCost(of: parent, limit: limit) }
    func weight(of id: Int) -> UInt64 {
        counter.weights += 1
        return base.weight(of: id)
    }
    func row(for id: Int) -> ScopeRow? {
        counter.rows += 1
        return base.row(for: id)
    }
    func rowCost(of id: Int) -> Int { base.rowCost(of: id) }
    func info(of id: Int) -> (name: String, kind: NodeKind)? {
        counter.infos += 1
        return base.info(of: id)
    }
    func largestChildren(of parent: Int?, limit: Int) -> (items: [(id: Int, weight: UInt64)], total: Int, cost: Int) {
        let found = base.largestChildren(of: parent, limit: limit)
        counter.selected += found.cost
        return found
    }
    func sampleCategories(under id: Int, visits: Int) -> (categories: [FileCategory: UInt64]?, consumed: Int) {
        let result = base.sampleCategories(under: id, visits: visits)
        counter.sampled += result.consumed
        return result
    }
}
