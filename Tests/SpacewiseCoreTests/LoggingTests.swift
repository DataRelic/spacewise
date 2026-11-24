import Foundation
import OSLog
import Testing

@testable import SpacewiseCore

/// The core logs scan start, finish, cancel and failure with counts, durations and codes, and never a path, a file
/// name or a volume name. Read back from this process's own log store.
struct LoggingTests {
    private func messages(since start: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@", SpacewiseLog.subsystem)
        return try store.getEntries(at: store.position(date: start), matching: predicate)
            .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
    }

    /// Nothing that names a location may appear, and every value is public, so nothing is redacted either.
    private func expectNoLocations(
        _ messages: [String], _ forbidden: [String], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for message in messages {
            for text in forbidden + ["<private>", "/"] {
                #expect(!message.contains(text), "\(message)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func scanLogsCountsAndDurationsButNoLocations() async throws {
        let marker = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spacewise-log-" + marker)
        let locked = root.appendingPathComponent("locked-" + marker)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("private-name-" + marker + ".txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        let start = Date().addingTimeInterval(-1)
        let finished = await Scanner.scan(plan: ScanPlan(folder: root), update: { _ in })
        #expect(finished.progress.state == .limited)
        let invalid = await Scanner.scan(
            plan: ScanPlan(folder: root.appendingPathComponent("missing-" + marker)),
            update: { _ in })
        #expect(invalid.progress.state == .invalid)
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Scanner.scan(plan: ScanPlan(folder: root), update: { _ in })
        }.value
        #expect(cancelled.progress.state == .cancelled)

        let logged = try messages(since: start)
        #expect(logged.contains { $0.hasPrefix("scan started scope=folder roots=1") })
        #expect(
            logged.contains {
                $0.hasPrefix("scan finished state=limited entries=2 ") && $0.contains("denied=1")
                    && $0.contains("errno=13x1") && $0.contains("elapsedMs=")
            })
        #expect(
            logged.contains {
                $0.hasPrefix("scan failed state=invalid roots=0 ") && $0.contains("vanished=1")
                    && $0.contains("errno=2x1")
            })
        #expect(logged.contains { $0.hasPrefix("scan cancelled ") })
        expectNoLocations(logged, [marker, root.path, "private-name", "locked", "spacewise-log"])
    }

    @Test func discoveryFailuresLogTheirCodeButNotTheToolOrItsArguments() throws {
        let start = Date().addingTimeInterval(-1)
        let secret = "/private/secret-" + UUID().uuidString
        let underlying = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSFilePathErrorKey: secret])
        let result = DriveDiscovery.discover(
            plist: { _ throws(MetadataToolError) in
                throw .spawnFailed(executable: secret, underlying: underlying)
            }, identity: { _ in nil })
        // The detail kept in the local coverage record still names the cause in full.
        #expect(result.unresolved.first?.contains(secret) == true)
        let logged = try messages(since: start)
        #expect(logged.contains("metadata query failed code=spawnFailed value=-1"))
        expectNoLocations(logged, [secret, "secret-", "diskutil"])
    }
}
