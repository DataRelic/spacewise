import AppKit
import Darwin
import Quartz
import SpacewiseAppModel
import SpacewiseCore
import SpacewiseFixtures
import Testing

@testable import SpacewiseApp

@MainActor struct ItemHandoffTests {
    private struct Fixture {
        let root: URL

        init() throws {
            // Use a neutral, writable location outside the system-managed temporary directory.
            root = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
                .appendingPathComponent("spacewise-handoff-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        func file(_ name: String = "sample.txt") throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data("Disposable preview fixture\n".utf8).write(to: url)
            return url
        }

        func scan(_ url: URL) async throws -> ItemHandoffTarget {
            let result = await Scanner.scan(plan: ScanPlan(folder: root), update: { _ in })
            let row = try #require(result.nodes.first { $0.name == url.lastPathComponent })
            let logicalRow = try #require(result.logicalRow(for: row.id))
            return try #require(ItemHandoffTarget(result: result, row: logicalRow))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func openReportsRefusalAndPassesTheValidatedPath() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.file()
        let target = try await fixture.scan(url)
        var calls: [URL] = []
        let refusal = ItemActions.open(target) {
            calls.append($0)
            return false
        }
        #expect(calls == [url])
        #expect(refusal.failure == .refused)
        #expect(refusal.failure?.notice(for: url.lastPathComponent).contains("macOS") == true)
        let accepted = ItemActions.open(target) { $0 == url }
        _ = try accepted.get()
    }

    @Test func mergedFolderKeepsItsFinderPathWithoutAPhysicalHandoffTarget() throws {
        let result = PresentationFixtures.wholeDrive()
        let group = LogicalNamespace.managedGroupID
        let id = try #require(
            result.namespace.list(for: group)?.first { result.logicalNode(for: $0)?.name == "System" })
        let row = try #require(result.logicalRow(for: id))
        #expect(result.namespace.isMerged(id))
        #expect(result.revealURL(for: id) == URL(fileURLWithPath: "/System"))
        #expect(ItemHandoffTarget(result: result, row: row) == nil)
    }

    @Test func missingReplacementAndRescanUseDifferentIdentities() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.file()
        let target = try await fixture.scan(url)
        // Retain the original so the filesystem cannot reuse its inode.
        try FileManager.default.moveItem(at: url, to: fixture.root.appendingPathComponent("original.txt"))
        #expect(ItemActions.preview(target).failure == .missing)
        #expect(
            ItemActions.open(target) { _ in
                Issue.record("Unexpected Open")
                return true
            }.failure == .missing)

        _ = try fixture.file()
        #expect(ItemActions.preview(target).failure == .changed)
        #expect(
            ItemActions.open(target) { _ in
                Issue.record("Unexpected Open")
                return true
            }.failure == .changed)
        #expect(ItemActions.exists(url))
        #expect(ItemHandoffTarget.Failure.changed.notice(for: url.lastPathComponent).contains("Rescan"))
        let refreshed = try await fixture.scan(url)
        #expect(try ItemActions.preview(refreshed).get() == url)
        _ = try ItemActions.open(refreshed) { $0 == url }.get()
    }

    @Test func symlinkSubstitutionsAreRejectedButThePathStillExists() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.file()
        let target = try await fixture.scan(url)
        let moved = fixture.root.appendingPathComponent("original.txt")
        try FileManager.default.moveItem(at: url, to: moved)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: moved)
        #expect(ItemActions.preview(target).failure == .changed)
        #expect(ItemActions.exists(url))

        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: moved, to: url)
        let relocated = fixture.root.appendingPathExtension("relocated")
        defer { try? FileManager.default.removeItem(at: relocated) }
        try FileManager.default.moveItem(at: fixture.root, to: relocated)
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: relocated)
        // The leaf inode is identical through this symlink.
        #expect(ItemActions.preview(target).failure == .changed)
    }

    @Test func currentFlagsModeAndPermissionsDriveTheHandoff() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.file()
        let target = try await fixture.scan(url)
        var metadata = stat()
        try #require(lstat(url.path, &metadata) == 0)
        metadata.st_flags |= UInt32(SF_DATALESS)
        #expect(target.currentFacts { _ in .success(metadata) }.failure == .unavailable)
        try #require(chmod(url.path, 0o700) == 0)
        #expect(
            ItemActions.open(target) { _ in
                Issue.record("Unexpected Open")
                return true
            }.failure == .restricted)
        #expect(try ItemActions.preview(target).get() == url)
        if geteuid() != 0 {
            try #require(chmod(url.path, 0o000) == 0)
            #expect(ItemActions.preview(target).failure == .unavailable)
            #expect(
                ItemActions.open(target) { _ in
                    Issue.record("Unexpected Open")
                    return true
                }.failure == .unavailable)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPACEWISE_NATIVE_HANDOFF_TEST"] == "1"))
    func nativeWorkspaceRefusalAndQuickLookRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let invalidApp = fixture.root.appendingPathComponent("Unlaunchable.app", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidApp, withIntermediateDirectories: false)
        let unlaunchable = try await fixture.scan(invalidApp)
        #expect(ItemActions.open(unlaunchable).failure == .refused)

        _ = NSApplication.shared
        let first = try fixture.file()
        let second = try fixture.file("second.txt")
        let firstTarget = try await fixture.scan(first)
        let secondTarget = try await fixture.scan(second)
        let panel = try #require(QLPreviewPanel.shared())
        let coordinator = QuickLookCoordinator()
        defer {
            coordinator.close()
            coordinator.end(panel)
        }
        var reportedFailure: ItemHandoffTarget.Failure?
        coordinator.onFailure = { _, failure in reportedFailure = failure }
        coordinator.show(firstTarget)
        coordinator.begin(panel)
        #expect(panel.isVisible)
        #expect(coordinator.previewPanel(panel, previewItemAt: 0) as? URL == first)
        coordinator.selectionDidChange(to: secondTarget)
        #expect(coordinator.previewPanel(panel, previewItemAt: 0) as? URL == second)
        try FileManager.default.removeItem(at: second)
        #expect(coordinator.previewPanel(panel, previewItemAt: 0) == nil)
        coordinator.selectionDidChange(to: secondTarget)
        #expect(reportedFailure == .missing)
        #expect(coordinator.isShowing == false)
        // Quick Look orders out with an animation.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while panel.isVisible, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(20))
        }
        #expect(panel.isVisible == false)
        #expect(coordinator.numberOfPreviewItems(in: panel) == 0)
    }
}

private extension Result where Failure == ItemHandoffTarget.Failure {
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}
