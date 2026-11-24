import Foundation
import Testing

@testable import SpacewiseCore

/// The namespace builder reports its work to the index's optional observer, like the index itself, and keeps no
/// counters of its own: a real scan installs no observer, so nothing is counted on the scan path.
struct NamespaceWorkReportingTests {
    /// System and Data roots, each with a shared folder ("Library", merged) and one unique file.
    private func tree() -> [ScanNode] {
        var nodes: [ScanNode] = []
        func add(_ parent: Int?, _ name: String, _ kind: NodeKind) -> Int {
            let id = nodes.count
            nodes.append(
                ScanNode(
                    id: id, parent: parent, name: name, kind: kind, device: parent == nil ? UInt64(id) : 0,
                    inode: UInt64(id + 1)))
            return id
        }
        let system = add(nil, "/", .directory)
        let data = add(nil, StartupDrive.dataVolumePath, .directory)
        _ = add(system, "Library", .directory)
        _ = add(system, "system-only", .file)
        _ = add(data, "Library", .directory)
        _ = add(data, "data-only", .file)
        return nodes
    }

    @Test func aCountedIndexReportsTheBuildersWork() {
        let nodes = tree()
        var index = ProgressiveIndex.counted()
        for node in nodes { index.append(node) }
        let urls = [URL(fileURLWithPath: "/"), URL(fileURLWithPath: StartupDrive.dataVolumePath)]
        let namespace = index.logicalNamespace(nodes: nodes, urls: urls, coverage: LocationCoverage(wholeDrive: true))
        #expect(namespace.unified && namespace.members.count == 1)
        // Four children are admitted to name groups; the two "Library" entries share a group, re-evaluated once.
        #expect(index.namespaceVisitCount == 4)
        #expect(index.namespaceReconcileCount == 1)
        #expect(index.namespaceSettleCount == 0)
        _ = index.logicalNamespace(
            nodes: nodes, urls: urls, coverage: LocationCoverage(wholeDrive: true), settled: true)
        #expect(index.namespaceSettleCount == 1)
        #expect(index.namespaceVisitCount == 4, "nothing new to admit")
    }

    @Test func aBuilderWithAnObserverReportsEachChildItAdmits() {
        let nodes = tree()
        var ranges: [Int: Range<Int>] = [:]
        for node in nodes {
            guard let parent = node.parent else { continue }
            ranges[parent] = (ranges[parent]?.lowerBound ?? node.id)..<(node.id + 1)
        }
        let environment = NamespaceBuilder.Environment(
            nodes: nodes, cancelled: { false }, bytes: { _ in (0, 0) },
            children: { parent, limit in Array((ranges[parent] ?? 0..<0).filter { $0 < limit }) })
        let work = IndexWorkCounter()
        var builder = NamespaceBuilder(observer: work)
        #expect(builder.advance(environment, rootPaths: [0: "/", 1: StartupDrive.dataVolumePath]) == .done)
        #expect(work.current.namespaceVisits == 4)
        #expect(work.current.namespaceReconciles == 1)
    }
}
