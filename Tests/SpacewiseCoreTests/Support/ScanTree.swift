import Foundation
import Testing

@testable import SpacewiseCore

// Synthetic scan trees and the helpers that drive the index and namespace the way the scanner does.

let systemURL = URL(fileURLWithPath: "/")
let dataURL = URL(fileURLWithPath: "/System/Volumes/Data")
let wholeDrive = LocationCoverage(wholeDrive: true)
let managedGroup = LogicalNamespace.managedGroupID

/// Nodes in scanner order: parents precede children and each directory's children are appended together.
struct Tree {
    var nodes: [ScanNode] = []
    @discardableResult mutating func root(_ name: String = "/") -> Int {
        let id = nodes.count
        nodes.append(
            ScanNode(id: id, parent: nil, name: name, kind: .directory, device: UInt64(id + 1), inode: UInt64(id + 1)))
        return id
    }
    @discardableResult mutating func add(
        _ parent: Int, _ name: String, _ kind: NodeKind = .directory, bytes: UInt64 = 0,
        issue: CoverageIssue? = nil, unknown: Bool = false
    ) -> Int {
        let id = nodes.count
        var node = ScanNode(
            id: id, parent: parent, name: name, kind: kind, logicalBytes: bytes == 0 ? 0 : bytes - 7,
            allocatedBytes: bytes,
            allocationUnknown: unknown, issue: issue, device: 1, inode: UInt64(id + 1))
        node.issue = issue
        nodes.append(node)
        return id
    }
}

/// What the scanner does for each node it discovers: append, and attribute a file's bytes to its ancestors.
func admit(_ index: inout ProgressiveIndex, _ nodes: [ScanNode], _ range: Range<Int>) {
    for id in range {
        index.append(nodes[id])
        if nodes[id].kind == .file {
            index.attribute(
                logical: nodes[id].logicalBytes, allocated: nodes[id].allocatedBytes, to: nodes[id].parent, nodes: nodes
            )
        }
    }
}

/// Root paths in root order: System, Data, then any auxiliary volumes.
func rootURLs(_ index: ProgressiveIndex, _ nodes: [ScanNode], auxiliary: [String] = []) -> [URL] {
    [systemURL, dataURL] + auxiliary.prefix(max(0, index.roots.count - 2)).map { URL(fileURLWithPath: $0) }
}

func namespace(_ index: inout ProgressiveIndex, _ nodes: [ScanNode], auxiliary: [String] = [], settled: Bool = false)
    -> LogicalNamespace
{
    index.logicalNamespace(
        nodes: nodes, urls: rootURLs(index, nodes, auxiliary: auxiliary), coverage: wholeDrive, settled: settled)
}

/// The full-build oracle over the same physical children.
func oracle(_ index: ProgressiveIndex, _ nodes: [ScanNode], auxiliary: [String] = []) -> LogicalNamespace {
    let urls = rootURLs(index, nodes, auxiliary: auxiliary)
    var rootPaths: [Int: String] = [:]
    for (position, id) in index.roots.enumerated() { rootPaths[id] = urls[position].path }
    return LogicalNamespace.build(nodes: nodes, rootPaths: rootPaths, wholeDrive: true, isCancelled: { false }) {
        index.ranges[$0] ?? 0..<0
    }
}

func expectEquivalent(
    _ got: LogicalNamespace, _ expected: LogicalNamespace, nodes: [ScanNode], _ note: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(got.unified == expected.unified, "\(note) unified", sourceLocation: sourceLocation)
    #expect(got.members == expected.members, "\(note) members", sourceLocation: sourceLocation)
    #expect(got.hidden == expected.hidden, "\(note) hidden", sourceLocation: sourceLocation)
    #expect(
        got.mergedChildren.mapValues(Set.init) == expected.mergedChildren.mapValues(Set.init),
        "\(note) merged children", sourceLocation: sourceLocation)
    #expect(
        Set(got.topLevel) == Set(expected.topLevel) && got.topLevel.count == expected.topLevel.count,
        "\(note) top level", sourceLocation: sourceLocation)
    #expect(
        Set(got.managed) == Set(expected.managed) && got.managed.count == expected.managed.count, "\(note) managed",
        sourceLocation: sourceLocation)
    #expect(
        got.managedPhysicalRoots == expected.managedPhysicalRoots, "\(note) managed roots",
        sourceLocation: sourceLocation)
    #expect(got.managedSet == expected.managedSet, "\(note) managed set", sourceLocation: sourceLocation)
    for id in nodes.indices {
        #expect(
            got.parent(of: id, nodes: nodes) == expected.parent(of: id, nodes: nodes), "\(note) parent of \(id)",
            sourceLocation: sourceLocation)
    }
    for scope in [nil, managedGroup] + got.merged.keys.map({ Optional($0) }) {
        #expect(
            got.listCount(for: scope) == expected.listCount(for: scope),
            "\(note) list size \(String(describing: scope))", sourceLocation: sourceLocation)
        #expect(
            got.listCost(for: scope) == expected.listCost(for: scope), "\(note) list cost \(String(describing: scope))",
            sourceLocation: sourceLocation)
    }
}

/// The coverage a finished scan holds when every directory in `nodes` was read to the end, except those in `unfinished`.
func enumeratedCoverage(
    of nodes: [ScanNode], base: LocationCoverage = wholeDrive,
    unfinished: [Int: DirectoryEnumeration] = [:]
) -> LocationCoverage {
    var coverage = base
    for id in nodes.indices where nodes[id].kind == .directory {
        coverage.enumeration[id] = unfinished[id] ?? .enumerated
    }
    return coverage
}

/// `nodes` as the scanner leaves them at the end: directory totals summed and "unknown" propagated upward.
func finalize(_ nodes: [ScanNode], coverage: LocationCoverage) -> [ScanNode] {
    var result = nodes
    Scanner.finalizeCoverage(nodes: &result, coverage: coverage)
    return result
}

extension Tree {
    /// The nodes as the scanner leaves them when every directory was read to the end.
    var settledNodes: [ScanNode] { finalize(nodes, coverage: enumeratedCoverage(of: nodes)) }
}

/// Paired System/Data tree: `top` merged folders, each with `subs` merged folders, each with `files` files per volume.
/// Every System entry precedes its Data twin, so merges are always late (the twin arrives after the first side).
func pairedTree(top: Int, subs: Int, files: Int) -> Tree {
    var tree = Tree()
    let system = tree.root("/")
    let data = tree.root("/System/Volumes/Data")
    var topIDs: [Int] = []
    for root in [system, data] { for t in 0..<top { topIDs.append(tree.add(root, "dir\(t)")) } }
    var subIDs: [Int] = []
    for id in topIDs { for s in 0..<subs { subIDs.append(tree.add(id, "sub\(s)")) } }
    for id in subIDs {
        for f in 0..<files { tree.add(id, "f\(f).bin", .file, bytes: UInt64(4096 * (1 + (id + f) % 17))) }
    }
    return tree
}
