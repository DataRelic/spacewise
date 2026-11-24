import Foundation
import Synchronization
import Testing

@testable import SpacewiseCore

/// A folder the scanner refuses to open because it is no longer the folder it discovered is never read and never
/// retried, so it must end in the terminal `openFailed` state, not `unopened` ("not read yet").
struct TerminalEnumerationTests {
    @Test func folderReplacedBeforeItIsOpenedEndsInATerminalState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spacewise-identity-" + UUID().uuidString)
        let folder = root.appendingPathComponent("swapped")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        // Every clock read moves 250 ms, so progress is published after each entry: right after "swapped" is
        // discovered, and before it is opened, the folder is replaced by a new one at the same path.
        let swapped = Mutex(false)
        let result = await Scanner.scan(
            plan: ScanPlan(folder: root), injectedFailure: nil,
            clock: SteppingClock(step: .milliseconds(250)),
            update: { progress in
                guard progress.entries >= 1, !swapped.withLock({ $0 }) else { return }
                do {
                    try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("moved-away"))
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    swapped.withLock { $0 = true }
                } catch {
                    Issue.record("could not replace the folder: \(error)")
                }
            })
        try #require(swapped.withLock { $0 })
        // The first node named "swapped" is the one discovered before the replacement.
        let original = try #require(result.nodes.first { $0.name == "swapped" && $0.parent == 0 })
        #expect(original.issue == .interruptedVolume)
        #expect(result.coverage.enumeration[original.id] == .openFailed)
        #expect(result.coverageStatus(for: original.id) == .unavailable)
        #expect(result.coverage.records.contains { $0.nodeID == original.id && $0.operation == .identity })
    }
}

/// Folders the scanner decides never to read, and folders whose listing fails part-way, end in their own terminal
/// states. `unopened` means "not read yet" and `partial` means "still being listed", so neither may describe a folder
/// that is finished with.
struct SkippedAndFailedListingTests {
    @Test func folderWhoseListingFailsPartWayEndsInListingFailed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.root.appending(path: "broken")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for name in ["a", "b", "c"] { try Data("x".utf8).write(to: folder.appending(path: name)) }

        // The first read of "broken" succeeds; the second fails with EIO, so the listing stops part-way.
        let reads = Mutex(0)
        let result = await Scanner.scan(
            plan: ScanPlan(folder: fixture.root),
            injectedFailure: { operation, path in
                guard operation == .readdir, path.hasSuffix("/broken") else { return nil }
                let count = reads.withLock { value -> Int in
                    value += 1
                    return value
                }
                return count == 2 ? EIO : nil
            }, update: { _ in })

        let broken = try #require(result.nodes.first { $0.name == "broken" })
        #expect(broken.issue == .enumeration)
        #expect(result.coverage.enumeration[broken.id] == .listingFailed)
        #expect(result.coverageStatus(for: broken.id) == .unavailable)
        #expect(result.coverage.enumeration[0] == .enumerated, "the root itself was listed to the end")
    }

    @Test func folderExcludedByPolicyEndsSkipped() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let excludedFolder = fixture.root.appending(path: "excluded")
        try FileManager.default.createDirectory(at: excludedFolder, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: excludedFolder.appending(path: "inside.txt"))
        // The scanner resolves the root's symbolic links (/var is /private/var), so the exclusion names the resolved path.
        let excludedPath = excludedFolder.resolvingSymlinksInPath().path
        let plan = ScanPlan(folder: fixture.root, policy: ScanPolicy(alsoExcluding: [excludedPath]))

        let result = await Scanner.scan(plan: plan, injectedFailure: nil, update: { _ in })

        let excluded = try #require(result.nodes.first { $0.name == "excluded" })
        #expect(excluded.issue == .policyExcluded)
        #expect(result.coverage.enumeration[excluded.id] == .skipped)
        #expect(result.coverageStatus(for: excluded.id) == .policyExcluded)
        #expect(!result.nodes.contains { $0.name == "inside.txt" }, "a skipped folder is never opened")
    }

    @Test func skippedAndFailedFoldersReadAsTheirIssueNotTheirListingState() {
        // The UI shows a node's issue in preference to its enumeration state, so the new states change no wording.
        for (issue, old, new) in [
            (CoverageIssue.policyExcluded, DirectoryEnumeration.unopened, DirectoryEnumeration.skipped),
            (.volumeBoundary, .unopened, .skipped), (.placeholder, .unopened, .skipped),
            (.enumeration, .partial, .listingFailed),
        ] {
            for provisional in [false, true] {
                let before = EmptyScope.make(
                    scopeName: "Folder", enumeration: old, issue: issue, state: .limited,
                    provisional: provisional)
                let after = EmptyScope.make(
                    scopeName: "Folder", enumeration: new, issue: issue, state: .limited,
                    provisional: provisional)
                #expect(before == after)
            }
            let node = ScanNode(id: 1, parent: 0, name: "Folder", kind: .directory, device: 1, inode: 2)
            var withIssue = node
            withIssue.issue = issue
            let status = NodeCoverageStatus(issue: issue, enumeration: new, allocationUnknown: true)
            #expect(status == NodeCoverageStatus(issue: issue, enumeration: old, allocationUnknown: true))
            let rowBefore = RowPresentation(
                row: ScopeRow(
                    node: withIssue, classification: .personal, coverage: status,
                    enumeration: old), provisional: true, scopeAllocated: 0)
            let rowAfter = RowPresentation(
                row: ScopeRow(
                    node: withIssue, classification: .personal, coverage: status,
                    enumeration: new), provisional: true, scopeAllocated: 0)
            #expect(rowBefore.detail == rowAfter.detail && rowBefore.coverage == rowAfter.coverage)
        }
    }
}
