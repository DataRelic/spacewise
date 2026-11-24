import Darwin
import Foundation
import Synchronization
import Testing

@testable import SpacewiseCore

/// How the scanner behaves when the filesystem changes under it or has an awkward shape. Every fixture is built in a
/// temporary directory the test creates and removes; nothing here reads the home folder or the startup disk.
struct ScanRobustnessTests {
    private func write(_ bytes: Int, to url: URL) throws {
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    // MARK: Entries that disappear while the scan runs

    @Test func fileThatVanishesBetweenListingAndStatIsReportedAsVanished() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for name in ["a", "b", "c"] {
            try write(4096, to: fixture.root.appending(path: name))
        }

        let result = await Scanner.scan(
            plan: ScanPlan(folder: fixture.root),
            injectedFailure: { operation, path in
                // The entry has been listed. Remove it before the scanner asks for its metadata.
                if operation == .fstatat, path.hasSuffix("/b") { unlink(path) }
                return nil
            },
            update: { _ in })

        #expect(result.progress.state == .limited)
        #expect(result.progress.issues[.vanished] == 1)
        #expect(result.progress.entries == 2)
        #expect(result.progress.logicalBytes == 8192)
        #expect(!result.nodes.contains { $0.name == "b" })
        #expect(result.nodes[0].allocationUnknown, "a folder that lost an entry mid-scan is a lower bound")
        #expect(result.coverageStatus(for: 0) == .partial)
        let record = try #require(result.coverage.records.first)
        #expect(record.operation == .fstatat)
        #expect(record.reason == .vanished)
        #expect(record.errnoCode == ENOENT)
        #expect(record.parentID == 0)
    }

    @Test func folderThatVanishesBeforeItIsOpenedEndsInATerminalState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for folder in ["one", "two"] {
            let url = fixture.root.appending(path: folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try write(4096, to: url.appending(path: "file"))
        }

        // The root has been listed, so both folders are queued. When the first is opened, remove the other.
        let firstOpened = Mutex<String?>(nil)
        let result = await Scanner.scan(
            plan: ScanPlan(folder: fixture.root),
            injectedFailure: { operation, path in
                guard operation == .fdopendir, let name = ["one", "two"].first(where: { path.hasSuffix("/" + $0) })
                else { return nil }
                let isFirst = firstOpened.withLock { value in
                    guard value == nil else { return false }
                    value = name
                    return true
                }
                if isFirst {
                    let other = name == "one" ? "two" : "one"
                    let victim = URL(fileURLWithPath: path).deletingLastPathComponent().appending(path: other)
                    try? FileManager.default.removeItem(at: victim)
                }
                return nil
            },
            update: { _ in })

        let survivor = try #require(firstOpened.withLock { $0 })
        let victim = survivor == "one" ? "two" : "one"
        let gone = try #require(result.nodes.first { $0.name == victim })
        let kept = try #require(result.nodes.first { $0.name == survivor })
        #expect(result.progress.state == .limited)
        #expect(
            result.progress.entries == 3,
            "two folders and the survivor's file; the vanished folder's file was never seen")
        #expect(gone.issue != nil, "a folder that cannot be read must not look complete")
        #expect(gone.allocationUnknown)
        #expect(result.coverageStatus(for: gone.id) == .unavailable)
        #expect(result.coverageStatus(for: kept.id) == .measured)
        #expect(result.nodes[0].allocationUnknown)
        #expect(result.nodes[0].logicalBytes == 4096)

        // The same fault as an unreadable entry elsewhere (ENOENT) is `.vanished`, with its errno.
        #expect(gone.issue == .vanished)
        #expect(result.coverage.enumeration[gone.id] == .openFailed, "a folder that was never listed is terminal")
        #expect(result.coverage.enumeration[kept.id] == .enumerated)
        #expect(result.progress.issues[.vanished] == 1)
        #expect(result.progress.issues[.interruptedVolume] == nil, "nothing was replaced; the folder was removed")
        let record = try #require(result.coverage.records.first { $0.nodeID == gone.id })
        #expect(record.reason == .vanished)
        #expect(record.errnoCode == ENOENT)
        #expect(record.operation == .identity, "the failed lstat is the identity check made before opening")
    }

    // MARK: Cycles

    @Test(.timeLimit(.minutes(1)))
    func deepSymlinkCyclesAreRecordedAndNeverFollowed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let depth = 30
        var directory = fixture.root
        for level in 0..<depth {
            let parent = directory
            directory = directory.appending(path: "d\(level)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            // Each level links back to its parent and to the scan root: following either would never end.
            try FileManager.default.createSymbolicLink(at: directory.appending(path: "up"), withDestinationURL: parent)
            try FileManager.default.createSymbolicLink(
                at: directory.appending(path: "top"), withDestinationURL: fixture.root)
        }
        try write(4096, to: directory.appending(path: "bottom"))
        // Two links that point at each other resolve to nothing at all (ELOOP).
        try FileManager.default.createSymbolicLink(
            atPath: fixture.root.appending(path: "x").path, withDestinationPath: "y")
        try FileManager.default.createSymbolicLink(
            atPath: fixture.root.appending(path: "y").path, withDestinationPath: "x")

        let result = await Scanner.scan(plan: ScanPlan(folder: fixture.root)) { _ in }

        let links = result.nodes.filter { $0.kind == .symbolicLink }
        #expect(links.count == 2 * depth + 2)
        #expect(result.progress.symbolicLinks == UInt64(2 * depth + 2))
        #expect(result.progress.entries == UInt64(depth + links.count + 1), "folders, links and the one real file")
        #expect(result.nodes.filter { $0.kind == .directory }.count == depth + 1, "the root and each level, once")
        #expect(result.progress.state == .completed)
        #expect(result.progress.issues.isEmpty)
        #expect(result.progress.logicalBytes == 4096)
        #expect(links.allSatisfy { $0.logicalBytes == 0 && $0.allocatedBytes == 0 })
    }

    // MARK: Empty files

    @Test func zeroByteFileIsAMeasuredFileOfNoSize() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(FileManager.default.createFile(atPath: fixture.root.appending(path: "empty").path, contents: nil))
        try write(1, to: fixture.root.appending(path: "one-byte"))

        let result = await Scanner.scan(plan: ScanPlan(folder: fixture.root)) { _ in }

        let empty = try #require(result.nodes.first { $0.name == "empty" })
        #expect(empty.kind == .file)
        #expect(empty.logicalBytes == 0)
        #expect(empty.allocatedBytes == 0)
        #expect(empty.issue == nil)
        #expect(!empty.allocationUnknown, "zero is a measurement, not an unknown")
        #expect(empty.hardLinkOwner == nil)
        #expect(result.coverageStatus(for: empty.id) == .measured)
        #expect(result.progress.entries == 2, "an empty file is still an entry")
        #expect(result.progress.logicalBytes == 1)
        #expect(result.progress.state == .completed)
    }

    @Test func folderHoldingOnlyAZeroByteFileIsCompleteNotEmptyOrInvalid() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(FileManager.default.createFile(atPath: fixture.root.appending(path: "empty").path, contents: nil))

        let discovery = try fixture.startupDiscovery()
        let result = await Scanner.scan(
            plan: ScanPlan(folder: fixture.root), injectedDiscovery: { discovery }, injectedFailure: nil,
            update: { _ in })

        #expect(result.progress.state == .completed)
        #expect(result.progress.entries == 1)
        #expect(result.progress.logicalBytes == 0)
        #expect(result.progress.allocatedBytes == 0)
        #expect(try #require(result.nodes.first).allocationUnknown == false)
        #expect(result.coverageStatus(for: 0) == .measured)
    }

    // MARK: Cancellation part-way through a folder

    @Test func cancellationAfterPartialEnumerationKeepsWhatWasReadAndMarksTheRestUnknown() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for (folder, files) in [("big", 50), ("later", 5)] {
            let url = fixture.root.appending(path: folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            for index in 0..<files {
                try write(1024, to: url.appending(path: "file-\(index)"))
            }
        }

        // The root's two entries are statted first; cancel on the twelfth stat, so a folder is cancelled part-way
        // through whichever order the two folders are opened in.
        let stats = Mutex(0)
        let worker = Task {
            await Scanner.scan(
                plan: ScanPlan(folder: fixture.root),
                injectedFailure: { operation, _ in
                    guard operation == .fstatat else { return nil }
                    let count = stats.withLock { value in
                        value += 1
                        return value
                    }
                    if count == 12 { withUnsafeCurrentTask { $0?.cancel() } }
                    return nil
                },
                update: { _ in })
        }
        let result = await worker.value

        #expect(result.progress.state == .cancelled)
        #expect(result.progress.entries < 2 + 50 + 5, "the scan stopped before reading everything")
        #expect(result.progress.entries >= 12, "entries read before the cancel are kept")
        #expect(result.nodes.count == Int(result.progress.entries) + 1)
        #expect(result.progress.logicalBytes > 0)
        #expect(result.nodes[0].logicalBytes == result.progress.logicalBytes, "partial totals still add up")
        let states = result.coverage.enumeration.values
        #expect(states.contains(.cancelled), "the folder being read is marked cancelled")
        #expect(!states.contains(.partial), "no folder is left looking as if it is still being read")
        #expect(result.nodes[0].allocationUnknown)
        #expect(result.coverageStatus(for: 0) != .measured)
        let interrupted = try #require(result.coverage.enumeration.first { $0.value == .cancelled }?.key)
        #expect(result.nodes[interrupted].allocationUnknown)
    }

    // MARK: Paths longer than PATH_MAX

    /// Creates `levels` nested folders, each named with `width` characters, and one file at the bottom. Paths that
    /// long cannot be passed to any path-based call, so the chain is built relative to open descriptors.
    private func makeDeepChain(under root: URL, levels: Int, width: Int) throws {
        var directory = open(root.path, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO) }
        defer { close(directory) }
        for level in 0..<levels {
            let name = String(repeating: Character(UnicodeScalar(UInt8(97 + level % 26))), count: width)
            guard mkdirat(directory, name, 0o755) == 0 else {
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            }
            let next = openat(directory, name, O_RDONLY | O_DIRECTORY)
            guard next >= 0 else { throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO) }
            close(directory)
            directory = next
        }
        let file = openat(directory, "deep.bin", O_CREAT | O_WRONLY, 0o600)
        guard file >= 0 else { throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO) }
        close(file)
    }

    @Test func pathBeyondPathMaxEndsInATerminalStateInsteadOfLookingComplete() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let width = 100
        let levels = 14  // far more than PATH_MAX allows below any temporary directory
        try makeDeepChain(under: fixture.root, levels: levels, width: width)
        let rootLength = fixture.root.resolvingSymlinksInPath().path.utf8.count
        // A path of PATH_MAX bytes or more (counting its NUL) cannot be passed to lstat or open.
        let reachableLevels = (Int(PATH_MAX) - 1 - rootLength) / (width + 1)
        try #require(reachableLevels >= 1 && reachableLevels < levels, "the fixture must straddle PATH_MAX")

        let result = await Scanner.scan(plan: ScanPlan(folder: fixture.root)) { _ in }

        #expect(result.progress.state == .limited)
        let folders = result.nodes.filter { $0.kind == .directory }
        #expect(folders.count == reachableLevels + 2, "the root, every level that fits, and the first that does not")
        let unreachable = try #require(folders.last)
        #expect(unreachable.issue != nil, "the first folder whose path does not fit must carry an issue")
        #expect(unreachable.allocationUnknown)
        #expect(folders.dropLast().allSatisfy { $0.issue == nil }, "every folder above it was read normally")
        #expect(!result.nodes.contains { $0.name == "deep.bin" }, "nothing below the limit is counted")
        #expect(result.nodes[0].allocationUnknown, "the totals above are a lower bound")

        // `statfs` on its path fails, which says nothing about the volume: the folder is unreadable, not excluded.
        #expect(unreachable.issue == .metadata)
        #expect(result.coverageStatus(for: unreachable.id) == .unavailable)
        #expect(result.coverage.enumeration[unreachable.id] == .openFailed, "never listed and never retried")
        #expect(result.progress.issues[.metadata] == 1)
        #expect(result.progress.issues[.volumeBoundary] == nil, "nothing here is another volume")
        #expect(result.progress.issues[.policyExcluded] == nil)
        let records = result.coverage.records.filter { $0.nodeID == unreachable.id }
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.reason == .metadata)
        #expect(record.errnoCode == ENAMETOOLONG)
        #expect(record.operation == .metadata)
    }

    @Test func fixtureRemovesAChainBeyondPathMax() throws {
        let fixture = try Fixture()
        try makeDeepChain(under: fixture.root, levels: 14, width: 100)
        fixture.remove()
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path), "a deep fixture must not be left behind")
    }
}
