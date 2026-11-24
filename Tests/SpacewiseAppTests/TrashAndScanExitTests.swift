import AppKit
import SpacewiseCore
import Testing
import os

@testable import SpacewiseApp

@MainActor private final class CommandTestWindow: NSWindow {
    private(set) var didClose = false
    override var isVisible: Bool { !didClose }
    override func close() { didClose = true }
}

/// Captures sheets without presenting them or handing anything off to Finder.
@MainActor private final class CommandDialogs {
    var pending: (alert: NSAlert, answer: Dialogs.AlertResponse)?
    var quitReplies: [Bool] = []

    func makeApp(mover: @escaping ItemActions.TrashMover = { _ in Issue.record("Unexpected Trash move") })
        -> AppDelegate
    {
        _ = NSApplication.shared
        let app = AppDelegate(
            presentAlert: { alert, _, answer in
                #expect(self.pending == nil)
                self.pending = (alert, answer)
            },
            trashMover: mover,
            replyToQuit: { self.quitReplies.append($0) })
        let window = CommandTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        app.window = window
        app.controller.app = app
        window.contentViewController = app.controller
        app.session.delegate = app
        return app
    }

    func respond(_ response: NSApplication.ModalResponse) throws {
        let current = try #require(pending)
        pending = nil
        current.answer(response)
    }
}

/// The scanner only sees Scope. The injected mover can rename within Base without touching system Trash.
private struct TrashFixture {
    let base: URL
    let scope: URL
    let folder: URL
    let selected: URL
    let other: URL
    let moved: URL

    init() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        base = home.appending(path: ".spacewise-trash-flow-\(UUID())", directoryHint: .isDirectory)
        scope = base.appending(path: "Scope", directoryHint: .isDirectory)
        folder = scope.appending(path: "Nested", directoryHint: .isDirectory)
        selected = scope.appending(path: "Selected")
        other = folder.appending(path: "Other")
        moved = base.appending(path: "Moved")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1]).write(to: selected)
            try Data([2]).write(to: other)
        } catch {
            remove()
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

@MainActor struct TrashFlowTests {
    private func waitFor<Value>(_ name: String, _ read: () -> Value?) async throws -> Value {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while clock.now < deadline {
            if let value = read() { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(name)")
        throw CancellationError()
    }

    private func scan(_ fixture: TrashFixture, in app: AppDelegate) async throws -> ScanResult {
        app.session.start(ScanPlan(folder: fixture.scope))
        let task = try #require(app.session.scanTask)
        await task.value
        let result = try #require(app.session.result)
        #expect(result.progress.state == .completed)
        return result
    }

    private func menuItem(_ app: AppDelegate, result: ScanResult, file: URL) throws -> NSMenuItem {
        let node = try #require(result.nodes.first { $0.name == file.lastPathComponent })
        let menu = ItemActions.rowMenu(target: app, node: node.id, canOpenFolder: false, open: .open)
        let item = try #require(menu.items.first { $0.action == #selector(AppDelegate.moveToTrash(_:)) })
        #expect(app.validateMenuItem(item))
        return item
    }

    private func refreshed(_ app: AppDelegate, after prior: ScanResult) async throws -> ScanResult {
        try await waitFor("the refreshed scan") {
            guard !app.session.isLive, let result = app.session.result, result.id != prior.id else { return nil }
            return result
        }
    }

    @Test func delayedMoveAllowsNavigationAndRescansOnlyItsConfirmedScope() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let calls = OSAllocatedUnfairLock(initialState: [URL]())
        let dialogs = CommandDialogs()
        let app = dialogs.makeApp { url in
            #expect(!Thread.isMainThread)
            calls.withLock { $0.append(url) }
            guard gate.wait(timeout: .now() + .seconds(8)) == .success else { throw CancellationError() }
            try FileManager.default.moveItem(at: url, to: fixture.moved)
        }
        defer { app.session.endCompletionConfirmation() }
        let result = try await scan(fixture, in: app)
        let originalMenuItem = try menuItem(app, result: result, file: fixture.selected)
        let otherMenuItem = try menuItem(app, result: result, file: fixture.other)

        app.moveToTrash(originalMenuItem)
        #expect(dialogs.pending?.alert.informativeText.contains(fixture.selected.path) == true)
        app.moveToTrash(otherMenuItem)
        try dialogs.respond(.alertSecondButtonReturn)
        _ = try await waitFor("the blocked mover") { calls.withLock { $0.first } }

        #expect(app.controller.state.status?.kind == .movingToTrash)
        let folder = try #require(result.nodes.first { $0.name == fixture.folder.lastPathComponent })
        app.openScope(folder.id)
        app.controller.selectFirstListedRow()
        #expect(app.session.currentParent == folder.id)
        #expect(app.controller.selectedNodeID == result.nodes.first { $0.name == fixture.other.lastPathComponent }?.id)
        let toolbarItem = NSToolbarItem(itemIdentifier: .init("test-trash"))
        toolbarItem.action = #selector(AppDelegate.moveToTrash(_:))
        #expect(!app.validateToolbarItem(toolbarItem))
        #expect(!app.validateMenuItem(otherMenuItem))
        app.moveToTrash(toolbarItem)
        app.moveToTrash(originalMenuItem)
        app.moveToTrash(otherMenuItem)
        #expect(!app.isEnabled(#selector(AppDelegate.rescan)))
        app.rescan()
        app.startFolderScan(fixture.folder)
        #expect(dialogs.pending == nil && !app.session.isLive)
        #expect(!app.windowShouldClose(app.window))
        #expect(app.applicationShouldTerminate(.shared) == .terminateCancel)

        gate.signal()
        let report = try await waitFor("the success report") { dialogs.pending?.alert }
        #expect(report.messageText == "Moved to Trash")
        #expect(report.informativeText.contains("Finder") && report.informativeText.contains("Put Back"))
        #expect(calls.withLock { $0 } == [fixture.selected])
        #expect(try Data(contentsOf: fixture.moved) == Data([1]))
        #expect(try Data(contentsOf: fixture.other) == Data([2]))
        try dialogs.respond(.alertFirstButtonReturn)
        let after = try await refreshed(app, after: result)
        #expect(after.roots == result.roots)
        #expect(!after.nodes.contains { $0.name == fixture.selected.lastPathComponent })
        #expect(after.nodes.contains { $0.name == fixture.other.lastPathComponent })
        #expect(!app.validateMenuItem(originalMenuItem))
    }

    @Test(arguments: [false, true])
    func staleTargetDoesNotReachMoverAndRefreshRequiresConsent(refresh: Bool) async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let dialogs = CommandDialogs()
        let app = dialogs.makeApp { _ in calls.withLock { $0 += 1 } }
        defer { app.session.endCompletionConfirmation() }
        let result = try await scan(fixture, in: app)
        let item = try menuItem(app, result: result, file: fixture.selected)
        app.moveToTrash(item)
        try FileManager.default.moveItem(at: fixture.selected, to: fixture.moved)
        try Data([3]).write(to: fixture.selected)
        try dialogs.respond(.alertSecondButtonReturn)

        let report = try await waitFor("the stale report") { dialogs.pending?.alert }
        #expect(report.buttons.map(\.title) == ["Cancel", "Refresh"])
        #expect(report.informativeText.contains(fixture.selected.path))
        #expect(calls.withLock { $0 } == 0)
        #expect(try Data(contentsOf: fixture.selected) == Data([3]))
        try dialogs.respond(refresh ? .alertSecondButtonReturn : .alertFirstButtonReturn)
        if refresh {
            let after = try await refreshed(app, after: result)
            #expect(after.roots == result.roots)
            _ = try menuItem(app, result: after, file: fixture.selected)
        } else {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(app.session.result?.id == result.id && !app.session.isLive)
        }
        #expect(!app.validateMenuItem(item))
    }

    @Test func cancellingConfirmationAndRetryingAfterPermissionFailure() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let calls = OSAllocatedUnfairLock(initialState: [URL]())
        let dialogs = CommandDialogs()
        let app = dialogs.makeApp { url in
            let count = calls.withLock { urls in
                urls.append(url)
                return urls.count
            }
            if count == 1 { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: fixture.moved)
        }
        defer { app.session.endCompletionConfirmation() }
        let result = try await scan(fixture, in: app)
        let item = try menuItem(app, result: result, file: fixture.selected)
        app.moveToTrash(item)
        try dialogs.respond(.alertFirstButtonReturn)
        #expect(calls.withLock { $0.isEmpty })
        #expect(app.validateMenuItem(item))

        app.moveToTrash(item)
        try dialogs.respond(.alertSecondButtonReturn)
        let failure = try await waitFor("the permission failure") { dialogs.pending?.alert }
        #expect(failure.messageText == "Couldn’t move file to Trash")
        #expect(failure.buttons.map(\.title) == ["OK"])
        #expect(try Data(contentsOf: fixture.selected) == Data([1]))
        try dialogs.respond(.alertFirstButtonReturn)
        #expect(app.session.result?.id == result.id && !app.session.isLive)
        #expect(app.validateMenuItem(item))

        app.moveToTrash(item)
        try dialogs.respond(.alertSecondButtonReturn)
        let success = try await waitFor("the retry success") { dialogs.pending?.alert }
        #expect(success.messageText == "Moved to Trash")
        #expect(calls.withLock { $0 } == [fixture.selected, fixture.selected])
        try dialogs.respond(.alertFirstButtonReturn)
        _ = try await refreshed(app, after: result)
    }
}

@MainActor struct ScanExitFlowTests {
    enum Answer: CaseIterable { case keepScanning, stop, alreadySettled }

    @Test(arguments: [false, true], Answer.allCases)
    func closeAndQuitUseDistinctActionsAndHonorTheAnswer(quit: Bool, answer: Answer) async throws {
        let dialogs = CommandDialogs()
        let app = dialogs.makeApp()
        let window = try #require(app.window as? CommandTestWindow)
        defer { app.session.endCompletionConfirmation() }
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let result = await Scanner.scan(plan: ScanPlan(folder: fixture.scope)) { _ in }
        #expect(result.progress.state == .completed)
        let scan = Task {}
        app.session.scanTask = scan
        if quit {
            #expect(app.applicationShouldTerminate(.shared) == .terminateLater)
            #expect(app.applicationShouldTerminate(.shared) == .terminateLater)
            #expect(!app.windowShouldClose(window))
        } else {
            #expect(!app.windowShouldClose(window))
            #expect(!app.windowShouldClose(window))
            #expect(app.applicationShouldTerminate(.shared) == .terminateCancel)
        }

        let alert = try #require(dialogs.pending?.alert)
        #expect(alert.buttons.map(\.title) == ["Keep Scanning", quit ? "Stop and Quit" : "Stop and Close"])
        if answer == .alreadySettled {
            app.session.settle(result)
            #expect(!window.didClose && dialogs.quitReplies.isEmpty)
        }
        try dialogs.respond(answer == .keepScanning ? .alertFirstButtonReturn : .alertSecondButtonReturn)

        if answer == .keepScanning {
            #expect(app.session.isLive && !scan.isCancelled && !window.didClose)
            #expect(dialogs.quitReplies == (quit ? [false] : []))
            app.session.settle(result)
            #expect(!window.didClose)
        } else {
            if answer == .stop {
                #expect(scan.isCancelled && app.session.stopping)
                #expect(!window.didClose && dialogs.quitReplies.isEmpty)
                app.session.settle(result)
            } else {
                #expect(!scan.isCancelled)
            }
            #expect(window.didClose == !quit)
            #expect(dialogs.quitReplies == (quit ? [true] : []))
            #expect(app.session.result?.progress.state == (answer == .stop ? .cancelled : .completed))
        }
        #expect(dialogs.quitReplies == (quit ? [answer != .keepScanning] : []))
    }
}
