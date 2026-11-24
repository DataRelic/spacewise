import Darwin
import Foundation
import Synchronization
import Testing

@testable import SpacewiseCore

/// The live storage map is attached to a scope snapshot at most once a second per request, on the scanner's clock.
/// An injected clock lets the test check the rule at each publication.
struct ScanCadenceTests {
    private struct Publication {
        let at: Duration
        let request: ScopeRequest
    }

    @Test func liveMapIsAttachedExactlyWhenASecondHasPassedForTheSameRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spacewise-cadence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for d in 0..<12 {
            let folder = root.appendingPathComponent("dir-\(d)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for i in 0..<15 {
                try Data(repeating: 7, count: 4096).write(to: folder.appendingPathComponent("f\(i).bin"))
            }
        }
        // 70 ms per read: progress publishes every few entries, and maps are due only every several publications.
        let clock = SteppingClock(step: .milliseconds(70))
        let requests = Mutex<[Publication]>([])
        let snapshots = Mutex<[ScopeSnapshot]>([])
        let result = await Scanner.scan(
            plan: ScanPlan(folder: root),
            scopeRequest: {
                // Halfway through, the person opens another view: a new generation is due a map at once.
                let count = requests.withLock { $0.count }
                let request = ScopeRequest(parent: 0, generation: count < 40 ? 1 : 2, wantsTreemap: true)
                requests.withLock { $0.append(Publication(at: clock.elapsed, request: request)) }
                return request
            },
            scopeUpdate: { snapshot in snapshots.withLock { $0.append(snapshot) } },
            injectedFailure: nil, clock: clock, update: { _ in })
        let published = snapshots.withLock { $0 }
        let asked = requests.withLock { $0 }
        try #require(published.count == asked.count && published.count > 60, "\(published.count) publications")
        #expect(result.progress.state == .completed)

        var lastMap: Publication?
        var maps = 0
        var withheld = 0
        for (index, snapshot) in published.enumerated() {
            let publication = asked[index]
            #expect(snapshot.request == publication.request)
            let due: Bool
            if !snapshot.provisional {
                due = false  // the settled map comes from the result
            } else if let last = lastMap, last.request.generation == publication.request.generation,
                last.request.parent == publication.request.parent
            {
                due = publication.at - last.at >= .seconds(1)
            } else {
                due = true
            }
            #expect((snapshot.treemap != nil) == due, "publication \(index) at \(publication.at)")
            if snapshot.treemap != nil {
                maps += 1
                lastMap = publication
            } else if snapshot.provisional {
                withheld += 1
            }
        }
        // The rule was exercised both ways, and the new generation got its own map.
        #expect(maps >= 4 && withheld >= 10, "maps \(maps), withheld \(withheld)")
        #expect(published.contains { $0.request.generation == 2 && $0.treemap != nil })
        #expect(published.last?.provisional == false && published.last?.treemap == nil)
    }
    @Test(arguments: [CoverageOperation.fstatat, .fdopendir, .readdir])
    func sustainedFailuresPublishProgressAndLatestPage(operation: CoverageOperation) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root
        let identity = try #require(Scanner.volumeIdentity(root))
        let evidence = DiscoveredRoot(url: root, fsid: identity, device: "disk1s1", uuid: UUID(), disk: "disk1")
        let failureCount = 10
        for index in 0..<failureCount {
            let entry = root.appendingPathComponent("failure-\(index)")
            if operation == .fstatat {
                try Data().write(to: entry)
            } else {
                try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: false)
            }
        }

        // Only injected failures advance time, so successful entries cannot trigger either live publication.
        let clock = SteppingClock(step: .zero)
        let failures = Mutex(0)
        let initial = ScopeRequest(parent: 0)
        let page = ScopeRequest(generation: 2)
        let latest = ScopeRequest(
            parent: operation == .fstatat ? nil : 0, offset: operation == .fstatat ? 0 : 1, generation: 3)
        let requested = Mutex(initial)
        let snapshots = Mutex<[ScopeSnapshot]>([])
        let updates = Mutex<[ScanProgress]>([])
        let issue: CoverageIssue = operation == .fstatat ? .denied : .enumeration
        let result = await Scanner.scan(
            plan: ScanPlan(folder: root),
            scopeRequest: { requested.withLock { $0 } },
            scopeUpdate: { snapshot in snapshots.withLock { $0.append(snapshot) } },
            injectedDiscovery: { DriveDiscovery(evidence: [evidence], roots: [root], unresolved: []) },
            injectedFailure: { candidate, path in
                guard candidate == operation, URL(fileURLWithPath: path).lastPathComponent.hasPrefix("failure-")
                else { return nil }
                let count = failures.withLock {
                    $0 += 1
                    return $0
                }
                if count == 2 { requested.withLock { $0 = page } }
                if count == 6 { requested.withLock { $0 = latest } }
                clock.advance(by: .milliseconds(50))
                return EACCES
            },
            clock: clock,
            update: { progress in updates.withLock { $0.append(progress) } })

        let live = snapshots.withLock { $0.filter(\.provisional) }
        #expect(
            updates.withLock { $0.filter { $0.state == .scanning }.map { $0.issues[issue, default: 0] } }
                == [0, 4, 8])
        #expect(live.map { $0.progress.issues[issue, default: 0] } == [0, 4, 8])
        #expect(live.map(\.request) == [initial, page, latest])
        let latestSnapshot = try #require(live.last)
        #expect(latestSnapshot.scope.parent == latest.parent)
        #expect(latestSnapshot.rows.count == (operation == .fstatat ? 1 : failureCount - latest.offset))
        #expect(result.progress.state == .limited)
        #expect(result.progress.issues[issue] == UInt64(failureCount))
        #expect(result.coverage.events == UInt64(failureCount))
        #expect(result.coverage.records.allSatisfy { $0.operation == operation && $0.errnoCode == EACCES })
    }

}
