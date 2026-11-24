import Foundation
import Testing

@testable import SpacewiseCore

@Test func indexedNavigationMatchesReferenceAcrossWideAndDeepTrees() {
    var nodes = [ScanNode(id: 0, parent: nil, name: "Root", kind: .directory, device: 1, inode: 0)]
    for id in 1...10_000 {
        nodes.append(
            ScanNode(
                id: id, parent: 0, name: "Entry \(id % 19)", kind: .file,
                allocatedBytes: UInt64(id % 31), device: 1, inode: UInt64(id)))
    }
    for id in 10_001...11_000 {
        nodes.append(
            ScanNode(
                id: id, parent: id == 10_001 ? 0 : id - 1, name: "Depth",
                kind: .directory, device: 1, inode: UInt64(id)))
    }
    let result = ScanResult(
        id: UUID(), started: Date(), ended: Date(), roots: [URL(fileURLWithPath: "/Synthetic")],
        nodes: nodes, progress: ScanProgress(), volumes: [])
    for parent: Int? in [nil, 0, 1, 10_001, 10_999, 11_000] {
        let expected = nodes.filter { $0.parent == parent }.sorted {
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id < $1.id
        }.map(\.id)
        #expect(Array(result.childIDs(of: parent)) == expected)
    }
    #expect(result.childIDs(of: -1).isEmpty)
    #expect(result.childIDs(of: nodes.count).isEmpty)
    #expect(result.node(for: -1) == nil)
    #expect(result.url(for: nodes.count) == nil)
    #expect(result.url(for: 11_000)?.pathComponents.count == 1_002)
}

@Test func rootURLsFollowInsertionOrderDespiteDisplaySorting() {
    let nodes = [
        ScanNode(id: 0, parent: nil, name: "Z", kind: .directory, device: 1, inode: 0),
        ScanNode(id: 1, parent: 0, name: "first", kind: .file, device: 1, inode: 1),
        ScanNode(id: 2, parent: nil, name: "A", kind: .directory, device: 2, inode: 0),
        ScanNode(id: 3, parent: 2, name: "second", kind: .file, device: 2, inode: 1),
    ]
    let result = ScanResult(
        id: UUID(), started: Date(), ended: Date(),
        roots: [URL(fileURLWithPath: "/One"), URL(fileURLWithPath: "/Two")],
        nodes: nodes, progress: ScanProgress(), volumes: [])
    #expect(Array(result.childIDs(of: nil)) == [2, 0])
    #expect(result.url(for: 1)?.path == "/One/first")
    #expect(result.url(for: 3)?.path == "/Two/second")
    // The second scope starts at a nonzero slice index, as consumed by AppKit rows.
    let children = result.childIDs(of: 2)
    #expect(result.node(for: children[children.startIndex])?.name == "second")
}
