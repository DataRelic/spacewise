import Foundation
import Testing

@testable import SpacewiseCore

struct MergedFolderCoverageTests {
    /// One folder, "Users", that is real on both volumes, so the unified namespace merges it.
    private func mergedUsers() -> (tree: Tree, namespace: LogicalNamespace, primary: Int, twin: Int) {
        var tree = Tree()
        let system = tree.root("/")
        let data = tree.root("/System/Volumes/Data")
        let systemUsers = tree.add(system, "Users")
        let dataUsers = tree.add(data, "Users")
        tree.add(systemUsers, "a.bin", .file, bytes: 4096)
        tree.add(dataUsers, "b.bin", .file, bytes: 8192)
        var index = ProgressiveIndex()
        admit(&index, tree.nodes, 0..<tree.nodes.count)
        return (tree, oracle(index, tree.nodes), systemUsers, dataUsers)
    }

    private func measuredRow(_ node: ScanNode) -> ScopeRow {
        ScopeRow(node: node, classification: .personal, coverage: .measured, enumeration: .enumerated)
    }

    @Test func mergedFolderWithEveryMemberMeasuredReportsMeasured() throws {
        let fixture = mergedUsers()
        #expect(fixture.namespace.members[fixture.primary] == [fixture.primary, fixture.twin])
        let row = try #require(
            fixture.namespace.row(for: fixture.primary, nodes: fixture.tree.nodes) {
                measuredRow(fixture.tree.nodes[$0])
            })
        #expect(row.coverage == .measured)
        #expect(!row.node.allocationUnknown)
    }

    @Test func mergedFolderWithAMemberThatHasNoRowIsNotReportedAsMeasured() throws {
        let fixture = mergedUsers()
        let row = try #require(
            fixture.namespace.row(for: fixture.primary, nodes: fixture.tree.nodes) { id in
                id == fixture.twin ? nil : measuredRow(fixture.tree.nodes[id])
            })
        #expect(
            row.coverage == .partial, "a member that could not be read must not leave the merged folder fully covered")
        #expect(row.node.allocationUnknown, "the merged totals leave out the missing member, so they are a lower bound")
    }

    /// A settled whole-drive result for a tree whose directories were all read, except those in `unfinished`.
    private func settledResult(_ tree: Tree, unfinished: [Int: DirectoryEnumeration] = [:]) -> ScanResult {
        let coverage = enumeratedCoverage(of: tree.nodes, unfinished: unfinished)
        var progress = ScanProgress()
        progress.state = .limited
        return ScanResult(
            id: UUID(), started: Date(), ended: Date(), roots: [systemURL, dataURL],
            nodes: finalize(tree.nodes, coverage: coverage), progress: progress, coverage: coverage, volumes: [])
    }

    @Test func deniedSubfolderInsideAMergedFolderKeepsTheWholeChainPartial() throws {
        var tree = Tree()
        let system = tree.root("/")
        let data = tree.root("/System/Volumes/Data")
        let systemUsers = tree.add(system, "Users")
        let dataUsers = tree.add(data, "Users")
        // "Shared" exists on both volumes, so it is a merged folder inside the merged folder; the System side was denied.
        let deniedShared = tree.add(systemUsers, "Shared", issue: .denied)
        let dataShared = tree.add(dataUsers, "Shared")
        tree.add(dataShared, "readable.bin", .file, bytes: 8192)
        tree.add(systemUsers, "a.bin", .file, bytes: 4096)
        let result = settledResult(tree, unfinished: [deniedShared: .openFailed])
        #expect(result.namespace.members[systemUsers] == [systemUsers, dataUsers])
        #expect(result.namespace.members[deniedShared] == [deniedShared, dataShared])

        let shared = try #require(result.logicalRow(for: deniedShared))
        #expect(shared.coverage == .partial, "one member was denied, so the merged folder is not fully measured")
        #expect(shared.node.allocationUnknown)
        #expect(shared.node.allocatedBytes == 8192, "what could be read is still counted")
        #expect(
            try #require(result.scopeRow(for: deniedShared)).coverage == .denied, "the denied member itself says why")

        let users = try #require(result.logicalRow(for: systemUsers))
        #expect(users.coverage == .partial, "the denial must reach every merged ancestor")
        #expect(users.node.allocationUnknown)
        #expect(users.node.allocatedBytes == 8192 + 4096)
    }

    @Test func deniedSubfolderDoesNotMakeAnUntouchedSiblingPartial() throws {
        var tree = Tree()
        let system = tree.root("/")
        let data = tree.root("/System/Volumes/Data")
        let systemUsers = tree.add(system, "Users")
        let dataUsers = tree.add(data, "Users")
        let denied = tree.add(systemUsers, "Private", issue: .denied)
        let sysFine = tree.add(systemUsers, "Fine")
        let dataFine = tree.add(dataUsers, "Fine")
        tree.add(sysFine, "a.bin", .file, bytes: 4096)
        tree.add(dataFine, "b.bin", .file, bytes: 4096)
        let result = settledResult(tree, unfinished: [denied: .openFailed])
        let fine = try #require(result.logicalRow(for: sysFine))
        #expect(fine.coverage == .measured, "a denial in one folder does not taint its merged sibling")
        #expect(!fine.node.allocationUnknown)
        #expect(try #require(result.logicalRow(for: systemUsers)).coverage == .partial)
    }
}
