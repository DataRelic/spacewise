import AppKit
import SpacewiseCore
import Testing

@testable import SpacewiseApp

@MainActor struct ScanReplacementFlowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPACEWISE_REPLACEMENT_FLOW_TEST"] == "1"))
    func folderPickerAndOpenPreserveResultsAndAllowRetry() async throws {
        var pickerAnswer: Dialogs.FolderSelection?
        let app = AppDelegate { _, answer in pickerAnswer = answer }
        let application = NSApplication.shared
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            if let remaining = app.window.attachedSheet { app.window.endSheet(remaining, returnCode: .cancel) }
            app.session.scanTask?.cancel()
            app.session.treemapTask?.cancel()
            app.session.endCompletionConfirmation()
            app.window.orderOut(nil)
        }

        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        func folder(_ name: String, under parent: URL) throws -> URL {
            let url = parent.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let original = try folder("Original", under: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = try folder("Nested", under: original)
        try Data(repeating: 1, count: 4096).write(to: nested.appending(path: "Example"))
        let fromPicker = try folder("Picker", under: root)
        let fromOpen = try folder("Open", under: root)
        let replacement = try folder("Replacement", under: root)

        let clock = ContinuousClock()
        func waitFor<Value>(_ description: String, _ read: () -> Value?) async throws -> Value {
            let deadline = clock.now.advanced(by: .seconds(10))
            while clock.now < deadline {
                if let value = read() { return value }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("Timed out waiting for \(description)")
            throw CancellationError()
        }

        func sheet(after previous: NSWindow? = nil) async throws -> NSWindow {
            try await waitFor("the next sheet") {
                guard let sheet = app.window.attachedSheet, sheet !== previous else { return nil }
                return sheet
            }
        }

        app.application(application, open: [original])
        let firstScan = try #require(app.session.scanTask)
        await firstScan.value
        let result = try #require(app.session.result)
        let nestedID = try #require(result.nodes.first { $0.name == "Nested" }?.id)
        app.openScope(nestedID)
        await app.session.treemapTask?.value
        let originalMapRevision = app.session.treemapRevision

        app.controller.selectFirstListedRow()
        let selection = try #require(app.controller.selectedNodeID)

        app.scanFolder()
        let cancelledPicker = try #require(pickerAnswer)
        cancelledPicker(nil)
        #expect(app.session.result?.id == result.id && !app.session.isLive)

        app.scanFolder()
        let picker = try #require(pickerAnswer)
        cancelledPicker(replacement)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(app.window.attachedSheet == nil && !app.session.isLive)
        picker(fromPicker)
        let pickerConfirmation = try await sheet()
        try FileManager.default.removeItem(at: fromPicker)
        app.window.endSheet(pickerConfirmation, returnCode: .alertSecondButtonReturn)
        let pickerRefusal = try await sheet(after: pickerConfirmation)
        #expect(app.session.result?.id == result.id && app.session.currentParent == nestedID)
        #expect(app.session.treemapRevision == originalMapRevision)
        #expect(app.controller.selectedNodeID == selection)
        app.window.endSheet(pickerRefusal, returnCode: .alertFirstButtonReturn)

        app.application(application, open: [fromOpen])
        let cancelledReplacement = try await sheet()
        app.window.endSheet(cancelledReplacement, returnCode: .alertFirstButtonReturn)
        #expect(app.session.result?.id == result.id && !app.session.isLive)

        app.application(application, open: [fromOpen])
        let openConfirmation = try await sheet()
        try FileManager.default.removeItem(at: fromOpen)
        app.window.endSheet(openConfirmation, returnCode: .alertSecondButtonReturn)
        let openRefusal = try await sheet(after: openConfirmation)
        #expect(app.session.result?.id == result.id && app.session.currentParent == nestedID)
        #expect(app.session.treemapRevision == originalMapRevision)
        #expect(app.controller.selectedNodeID == selection)

        pickerAnswer = nil
        app.window.endSheet(openRefusal, returnCode: .alertSecondButtonReturn)
        let retryPicker = try await waitFor("the retry picker command") { pickerAnswer }
        retryPicker(replacement)
        let retryConfirmation = try await sheet(after: openRefusal)
        app.window.endSheet(retryConfirmation, returnCode: .alertSecondButtonReturn)
        let newResult = try await waitFor("replacement results") {
            app.session.result.flatMap { $0.id == result.id ? nil : $0 }
        }
        #expect(newResult.progress.state == .completed)
        #expect(app.session.scopeTitle == "Replacement" && app.session.currentParent == 0)
    }
}
