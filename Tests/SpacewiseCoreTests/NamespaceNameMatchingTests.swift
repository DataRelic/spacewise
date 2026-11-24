import Foundation
import Testing

@testable import SpacewiseCore

/// APFS stores the original spelling of a name while matching canonically equivalent Unicode.
struct NamespaceNameMatchingTests {
    @Test(arguments: [false, true])
    func equivalentUTF8SpellingsMergeInEitherArrivalOrder(dataFirst: Bool) throws {
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        try #require(composed.utf8.elementsEqual(decomposed.utf8) == false)
        try #require(composed == decomposed)

        var tree = Tree()
        let system = tree.root("/")
        let data = tree.root("/System/Volumes/Data")
        let first = tree.add(dataFirst ? data : system, dataFirst ? decomposed : composed)
        let second = tree.add(dataFirst ? system : data, dataFirst ? composed : decomposed)
        let systemFolder = dataFirst ? second : first
        let dataFolder = dataFirst ? first : second
        let systemFile = tree.add(systemFolder, "a.bin", .file, bytes: 4096)
        let dataFile = tree.add(dataFolder, "b.bin", .file, bytes: 8192)

        var index = ProgressiveIndex()
        admit(&index, tree.nodes, 0..<2)
        for next in 2..<tree.nodes.count {
            admit(&index, tree.nodes, next..<(next + 1))
            let nodes = Array(tree.nodes.prefix(next + 1))
            expectEquivalent(namespace(&index, nodes), oracle(index, nodes), nodes: nodes)
        }

        let coverage = enumeratedCoverage(of: tree.nodes)
        let result = ScanResult(
            id: UUID(), started: Date(), ended: Date(), roots: [systemURL, dataURL],
            nodes: finalize(tree.nodes, coverage: coverage), progress: ScanProgress(), coverage: coverage, volumes: [])
        let top = result.logicalChildIDs(of: nil).filter { result.logicalNode(for: $0)?.name == composed }
        let merged = try #require(top.first)
        #expect(top.count == 1)
        let members = try #require(result.namespace.members[merged])
        #expect(Set(members) == [systemFolder, dataFolder])
        #expect(Set(result.logicalChildIDs(of: merged)) == [systemFile, dataFile])
        let row = try #require(result.logicalRow(for: merged))
        #expect(row.node.allocatedBytes == 4096 + 8192)
        #expect(row.coverage == .measured)
    }
}
