import AppKit
import Foundation
import SpacewiseAppModel
import SpacewiseCore
import Testing

@testable import SpacewiseApp

@MainActor struct WideListQueryTests {
    private static func fixture(count: Int, merged: Bool) -> (result: ScanResult, wide: Int, empty: Int) {
        let data = "/System/Volumes/Data"
        var nodes: [ScanNode] = []
        func append(_ name: String, parent: Int?, kind: NodeKind = .directory, bytes: UInt64 = 0) {
            let id = nodes.count
            nodes.append(
                ScanNode(
                    id: id, parent: parent, name: name, kind: kind, allocatedBytes: bytes,
                    device: 1, inode: UInt64(id + 1)))
        }
        append("/", parent: nil)
        let wide: Int
        let empty: Int
        if merged {
            append(data, parent: nil)
            wide = 2
            append("Wide", parent: 0)
            append("Wide", parent: 1)
            empty = 4
            append("Empty", parent: 1)
        } else {
            wide = 1
            append("Wide", parent: 0)
            empty = 2
            append("Empty", parent: 0)
        }
        for offset in 0..<count {
            append(
                "item-\(count - offset)", parent: merged && offset.isMultiple(of: 2) ? wide + 1 : wide,
                kind: .file, bytes: UInt64(offset % 7 + 1))
        }
        var progress = ScanProgress()
        progress.state = .completed
        let roots = (merged ? ["/", data] : ["/"]).map { URL(fileURLWithPath: $0) }
        let result = ScanResult(
            id: UUID(), started: Date(), ended: Date(), roots: roots, nodes: nodes, progress: progress,
            coverage: LocationCoverage(wholeDrive: merged), volumes: [])
        return (result, wide, empty)
    }

    @Test(arguments: [false, true])
    func wideQueriesPreserveTiesAndDropObsoletePublications(merged: Bool) async throws {
        let (result, wide, empty) = Self.fixture(count: 2_000, merged: merged)
        let session = ScanSession()
        session.result = result
        session.navigate(to: wide)
        let firstBase = session.settledRows()
        if merged {
            #expect(result.namespace.isMerged(wide))
            #expect(firstBase == nil)
            #expect(ScreenStateBuilder.build(session.screenInputs(volume: nil)).state.total == 2_000)
            let obsolete = try #require(session.rowRankingTask)
            session.navigate(to: empty)
            await obsolete.value
            #expect(obsolete.isCancelled)
            #expect(session.settledRows()?.count == 0)
            session.navigate(to: wide)
            _ = session.settledRows()
            await session.rowRankingTask?.value
        } else {
            #expect(firstBase != nil && session.rowRankingTask == nil)
        }
        let base = try #require(session.settledRows())
        let cache = ListQueryCache()
        var publications = 0
        #expect(cache.requestRows(for: base, query: ListQuery()) { publications += 1 } === base)

        let nameSort = ListQuery(sort: ListSort(key: .name, ascending: true))
        #expect(cache.requestRows(for: base, query: nameSort) { publications += 100 } == nil)
        let obsolete = try #require(cache.task)
        let query = ListQuery(filter: " ITEM ", sort: ListSort(key: .allocated, ascending: true))
        #expect(cache.requestRows(for: base, query: query) { publications += 1 } == nil)
        #expect(cache.requestRows(for: base, query: query) { publications += 100 } == nil)
        await cache.task?.value
        await obsolete.value
        #expect(obsolete.isCancelled && publications == 1)
        let rows = try #require(cache.requestRows(for: base, query: query) { publications += 100 })
        let baseNodes = (0..<base.count).compactMap(base.node(at:))
        let expected = baseNodes.sorted { $0.allocatedBytes < $1.allocatedBytes }
        #expect((0..<rows.count).compactMap { rows.node(at: $0)?.id } == expected.map(\.id))
        #expect(rows.index(ofNode: expected.last!.id) == rows.count - 1)

        _ = cache.requestRows(for: base, query: nameSort) { publications += 100 }
        let leaving = try #require(cache.task)
        session.navigate(to: empty)
        let destination = try #require(session.settledRows())
        #expect(cache.requestRows(for: destination, query: ListQuery()) { publications += 100 } === destination)
        await leaving.value
        #expect(leaving.isCancelled && publications == 1)

        session.navigate(to: wide)
        _ = session.settledRows()
        await session.rowRankingTask?.value
        _ = cache.requestRows(for: session.settledRows(), query: nameSort) { publications += 100 }
        let replacing = try #require(cache.task)
        let replacement = Self.fixture(count: 500, merged: merged).result
        session.settle(replacement)
        #expect(session.currentParent == wide)
        _ = cache.requestRows(for: session.settledRows(), query: ListQuery()) { publications += 100 }
        await replacing.value
        await session.rowRankingTask?.value
        #expect(replacing.isCancelled && publications == 1)
        #expect(session.settledRows()?.result.id == replacement.id)
        #expect(session.settledRows()?.count == 500)
        session.endCompletionConfirmation()
        session.treemapTask?.cancel()
    }

    /// Run one cell per process to keep the process-wide RSS high-water mark independent.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPACEWISE_WIDE_QUERY"] != nil))
    func wideListInteractionBenchmark() async throws {
        let cell = try #require(ProcessInfo.processInfo.environment["SPACEWISE_WIDE_QUERY"])
        let fields = cell.split(separator: "-")
        let count = try #require(fields.first.flatMap { Int($0) })
        try #require(fields.count == 2 && count > 256 && ["plain", "merged"].contains(fields[1]))
        let merged = fields[1] == "merged"
        let (result, wide, empty) = Self.fixture(count: count, merged: merged)
        #expect(result.namespace.isMerged(wide) == merged)
        let app = AppDelegate()
        let application = NSApplication.shared
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        app.session.result = result
        app.listSortDidChange(nil)
        defer {
            app.session.treemapTask?.cancel()
            app.applicationWillTerminate(
                Notification(name: NSApplication.willTerminateNotification, object: application))
            app.window.orderOut(nil)
        }

        let clock = ContinuousClock()
        func milliseconds(_ duration: Duration) -> Double {
            let (seconds, attoseconds) = duration.components
            return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
        }
        func memory() -> String {
            let sample = ScanMemorySample.capture(phase: cell)
            return "rssBytes=\(sample.residentBytes ?? 0) peakRSSBytes=\(sample.peakRSSBytes ?? 0)"
        }
        func waitForRows(_ count: Int) async throws {
            let deadline = clock.now.advanced(by: .seconds(30))
            while app.controller.state.source?.count != count {
                try #require(clock.now < deadline)
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        func measure(_ label: String, rows: Int, _ action: () -> Void) async throws {
            let start = clock.now
            action()
            let returned = clock.now
            try await waitForRows(rows)
            print(
                "WIDE \(cell) \(label) handlerMs=\(milliseconds(start.duration(to: returned))) "
                    + "publishMs=\(milliseconds(start.duration(to: clock.now))) \(memory())")
        }

        let sampleTask = Task.detached {
            var peak: UInt64 = 0
            while !Task.isCancelled {
                let sample = ScanMemorySample.capture(phase: "wide-query")
                peak = max(peak, sample.residentBytes ?? 0)
                try? await Task.sleep(for: .milliseconds(1))
            }
            return peak
        }
        defer { sampleTask.cancel() }
        print("WIDE \(cell) baseline \(memory())")
        try await measure("navigate-wide", rows: count) { app.session.navigate(to: wide) }
        try await measure("filter", rows: count) { app.filterDidChange("item") }
        try await measure("clear", rows: count) { app.filterDidChange("") }
        try await measure("name-sort", rows: count) {
            app.listSortDidChange(ListSort(key: .name, ascending: true))
        }
        #expect(app.controller.state.source?.node(at: 0)?.name == "item-1")

        app.listSortDidChange(nil)
        let started = clock.now
        app.listSortDidChange(ListSort(key: .name, ascending: false))
        try await Task.sleep(for: .milliseconds(20))
        let resumed = clock.now
        try #require(app.controller.state.isPreparingRows)
        app.filterDidChange("item-")
        app.filterDidChange("item-1")
        let last = clock.now
        app.filterDidChange("absent")
        let lastReturned = clock.now
        try await waitForRows(0)
        #expect(app.controller.state.empty?.title == ProductCopy.Filter.noMatchesTitle)
        print(
            "WIDE \(cell) supersede-and-type mainResumeMs=\(milliseconds(started.duration(to: resumed))) "
                + "lastHandlerMs=\(milliseconds(last.duration(to: lastReturned))) lastPublishMs=\(milliseconds(last.duration(to: clock.now))) \(memory())"
        )

        app.filterDidChange("")
        try await Task.sleep(for: .milliseconds(20))
        try #require(app.controller.state.isPreparingRows)
        try await measure("navigate-away-during-sort", rows: 0) { app.session.navigate(to: empty) }
        app.listSortDidChange(nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(app.controller.state.summary?.parent == empty)
        #expect(app.controller.state.source?.count == 0)
        sampleTask.cancel()
        let interactionPeak = await sampleTask.value
        print("WIDE \(cell) final \(memory()) interactionSampledPeakRSSBytes=\(interactionPeak)")
    }
}
