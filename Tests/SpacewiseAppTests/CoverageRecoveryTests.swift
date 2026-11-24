import AppKit
import SpacewiseAppModel
import Testing

@testable import SpacewiseApp
@testable import SpacewiseCore

@MainActor struct CoverageRecoveryTests {
    @Test(arguments: [EACCES, EIO])
    func scannerFailuresKeepRecoveryAvailableAsResultsAge(_ error: Int32) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let unread = root.appending(path: "Unread")
        try FileManager.default.createDirectory(at: unread, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 4096).write(to: unread.appending(path: "Contents"))

        let plan = ScanPlan(folder: root)
        let identity = try #require(Scanner.volumeIdentity(root))
        let evidence = DiscoveredRoot(
            url: URL(fileURLWithPath: StartupDrive.dataVolumePath),
            fsid: identity, device: "disk3s5", uuid: UUID(), disk: "disk0")
        let discovery = DriveDiscovery(evidence: [evidence], roots: [evidence.url], unresolved: [])
        let failed = await Scanner.scan(
            plan: plan, injectedDiscovery: { discovery },
            injectedFailure: { operation, path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                if error == EACCES, operation == .fstatat, name == "Contents" { return error }
                if error == EIO, operation == .readdir, name == "Unread" { return error }
                return nil
            },
            update: { _ in })
        #expect(failed.progress.state == .limited)
        #expect(failed.nodes.contains { $0.name == "Contents" } == false)

        var inputs = ScreenInputs(
            phase: .settled, scopeTitle: "Fixture", isFolderScope: true, volume: nil, now: failed.ended,
            liveProgress: nil, liveSnapshot: nil, liveSource: nil, requestOffset: 0, result: failed,
            settledSource: SettledRows(result: failed, parent: 0), currentParent: 0, treemapModel: nil,
            treemapRevision: 0, hasPendingTreemap: false, canGoUp: false, isLive: false)
        let fresh = try #require(ScreenStateBuilder.build(inputs).state.status)
        inputs.now = failed.ended.addingTimeInterval(ResultFreshness.staleAfter)
        let aged = ScreenStateBuilder.build(inputs)
        #expect(aged.state.status == fresh)
        #expect(aged.windowSubtitle.hasSuffix("1 hour ago"))
        #expect(fresh.actions.contains(.coverageDetails))
        #expect(fresh.actions.contains(.rescan))
        #expect(fresh.actions.contains(.privacySettings) == (error == EACCES))
        let guidance = ScanDetails.make(failed.coverage).text
        #expect(guidance.contains("same scan again"))
        #expect(guidance.contains(ScanDetails.accessRecovery) == (error == EACCES))

        let retried = await Scanner.scan(
            plan: plan, injectedDiscovery: { discovery }, injectedFailure: nil, update: { _ in })
        #expect(retried.progress.state == .completed)
        #expect(retried.nodes.contains { $0.name == "Contents" })
        inputs.result = retried
        inputs.settledSource = SettledRows(result: retried, parent: 0)
        inputs.now = retried.ended
        #expect(ScreenStateBuilder.build(inputs).state.status == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPACEWISE_COVERAGE_RECOVERY_TEST"] == "1"))
    func settingsHandoffShowsManualDirectionsWhenOpeningFails() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 460),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
        }

        var requestedURL: URL?
        Dialogs.openFullDiskAccessSettings(on: window) { url in
            requestedURL = url
            return true
        }
        #expect(requestedURL?.scheme == "x-apple.systempreferences")
        #expect(requestedURL?.query == "Privacy_AllFiles")
        #expect(window.attachedSheet == nil)

        Dialogs.openFullDiskAccessSettings(on: window) { _ in false }
        let sheet = try #require(window.attachedSheet)
        let content = try #require(sheet.contentView)
        func labels(in view: NSView) -> [String] {
            if let field = view as? NSTextField { return [field.stringValue] }
            return view.subviews.flatMap { labels(in: $0) }
        }
        let text = labels(in: content).joined(separator: "\n")
        #expect(text.contains("System Settings → Privacy & Security → Full Disk Access"))
        #expect(text.contains("Rescan"))
        #expect(text.contains("quit and reopen"))
    }
}
