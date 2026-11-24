import Darwin
import Foundation
import Testing

@testable import SpacewiseCore

struct SystemTrashIntegrationTests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["SPACEWISE_SYSTEM_TRASH_TEST"] == "1",
            "Requires explicit opt-in from the disposable spacewise-trash-test account")
    )
    func systemTrashAndRescan() async throws {
        let uid = getuid()
        try #require(uid != 0 && uid == geteuid())
        let account = try #require(getpwuid(uid)?.pointee)
        try #require(String(cString: account.pw_name) == "spacewise-trash-test")
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let accountHome = URL(fileURLWithPath: String(cString: account.pw_dir)).resolvingSymlinksInPath()
        try #require(home.path == accountHome.path)
        let homeInfo = try #require(try entry(at: home))
        try #require(homeInfo.st_mode & S_IFMT == S_IFDIR && homeInfo.st_uid == uid)
        let trash = home.appending(path: ".Trash", directoryHint: .isDirectory)
        let trashInfo = try #require(try entry(at: trash))
        try #require(trashInfo.st_mode & S_IFMT == S_IFDIR && trashInfo.st_uid == uid)
        try #require(access(trash.path, W_OK | X_OK) == 0, "Use a terminal with access to this account's Trash")

        let fixture = try Fixture(base: home)
        defer {
            do {
                try fm.removeItem(at: fixture.root)
                #expect(try entry(at: fixture.root) == nil)
            } catch {
                Issue.record("Could not remove Trash fixture at \(fixture.root.path): \(error)")
            }
        }

        let file = fixture.root.appending(path: fixture.root.lastPathComponent + ".bin")
        let expectedDestination = trash.appending(path: file.lastPathComponent)
        let contents = Data(repeating: 42, count: 8192)
        try contents.write(to: file, options: .withoutOverwriting)
        let original = try #require(try entry(at: file))
        try #require(original.st_dev == trashInfo.st_dev, "Fixture and home Trash must share a volume")
        try #require(try entry(at: expectedDestination) == nil)

        let plan = ScanPlan(folder: fixture.root)
        let before = await Scanner.scan(plan: plan) { _ in }
        try #require(before.progress.state == .completed)
        let node = try #require(before.nodes.first { $0.name == file.lastPathComponent })
        let target = try #require(before.trashTarget(for: node.id))
        try #require(target.url.path == file.path)
        #expect(before.progress.allocatedBytes > 0)

        var reportedDestination: URL?
        defer {
            // Register before the move so a nil URL or a thrown assertion still restores the owned fixture.
            do {
                if try entry(at: file) == nil {
                    let candidates = [expectedDestination, reportedDestination].compactMap { $0 }
                    let destination = try #require(
                        try candidates.first { try matches(entry(at: $0), original) },
                        "Locate the fixture in Trash before disposing of this account")
                    try fm.moveItem(at: destination, to: file)
                    #expect(try entry(at: destination) == nil)
                }
                #expect(try matches(entry(at: file), original))
                #expect(try Data(contentsOf: file) == contents)
                #expect(try entry(at: expectedDestination) == nil)
            } catch {
                let path = reportedDestination?.path ?? expectedDestination.path
                Issue.record("Could not verify restoration of \(file.path) from \(path): \(error)")
            }
        }

        reportedDestination = try target.moveToTrash()
        let destination = try #require(reportedDestination)
        try #require(destination.resolvingSymlinksInPath().path == expectedDestination.path)
        #expect(try entry(at: file) == nil)
        #expect(try matches(entry(at: destination), original))
        #expect(try Data(contentsOf: destination) == contents)
        let after = await Scanner.scan(plan: plan) { _ in }
        #expect(after.progress.state == .completed)
        #expect(after.nodes.count == 1)
        #expect(after.progress.allocatedBytes == 0)
    }

    private func entry(at url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        let code = errno
        if code == ENOENT { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }

    private func matches(_ info: stat?, _ original: stat) -> Bool {
        info.map { $0.st_dev == original.st_dev && $0.st_ino == original.st_ino } == true
    }
}
