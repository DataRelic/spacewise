import Foundation
import Testing

@testable import SpacewiseCore

struct TrashTests {
    @Test func protectedLocationsAreInspectionOnly() {
        let home = URL(fileURLWithPath: "/Users/Example")
        for path in ["", "Documents", "lIbRaRy/Cache/x", ".Trash/x", "Applications/App", "sample.app/Contents/x"] {
            #expect(!TrashTarget.personalLocation(home.appending(path: path), home: home))
        }
        #expect(TrashTarget.personalLocation(home.appending(path: "Documents/personal"), home: home))
    }

    @Test(arguments: [false, true])
    func cleanAndChangedFoldersAreInspectionOnly(addProtectedChildAfterScan: Bool) async throws {
        let fm = FileManager.default
        let fixture = try Fixture(base: fm.homeDirectoryForCurrentUser)
        defer { fixture.remove() }
        let folder = fixture.root.appending(path: "personal-folder", directoryHint: .isDirectory)
        let file = folder.appending(path: "personal-file", directoryHint: .notDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data([42]).write(to: file)

        let result = await Scanner.scan(plan: ScanPlan(folder: fixture.root)) { _ in }
        let node = try #require(result.nodes.first { $0.name == folder.lastPathComponent })
        let row = try #require(result.logicalRow(for: node.id))
        let child = try #require(result.logicalChildIDs(of: node.id).first)
        let fileTarget = try #require(result.trashTarget(for: child))
        #expect(row.node.kind == .directory)
        #expect(row.coverage == .measured)
        #expect(row.eligibility == .inspectionOnly)
        #expect(result.url(for: node.id)?.path == folder.path)
        #expect(fileTarget.url.path == file.path)

        if addProtectedChildAfterScan {
            let link = folder.appending(path: "new-link")
            try fm.createSymbolicLink(at: link, withDestinationURL: file)
            #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == file.path)
        }

        // Force both paths through move-time validation using the directory's actual scanned identity.
        #expect(result.trashTarget(for: node.id) == nil)
        let folderTarget = TrashTarget(url: folder, scanID: result.id, node: node)
        #expect(throws: TrashTarget.Failure.changed) {
            try folderTarget.move { _ in Issue.record("Directory was passed to Trash") }
        }
        var mislabeled = node
        mislabeled.kind = .file
        let mislabeledTarget = TrashTarget(url: folder, scanID: result.id, node: mislabeled)
        #expect(throws: TrashTarget.Failure.changed) {
            try mislabeledTarget.move { _ in Issue.record("Directory labeled as a file was passed to Trash") }
        }
        var movedURL: URL?
        try fileTarget.move { movedURL = $0 }
        #expect(movedURL?.path == file.path)
        #expect(try Data(contentsOf: file) == Data([42]))
    }

    @Test func confirmedTargetIsBoundToScannedIdentity() async throws {
        let fixture = try Fixture(base: FileManager.default.homeDirectoryForCurrentUser)
        defer { fixture.remove() }
        let fm = FileManager.default
        let file = fixture.root.appending(path: "selected")
        let folder = fixture.root.appending(path: "folder")
        try Data([1]).write(to: file)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: folder.appending(path: "link"), withDestinationURL: file)
        let package = fixture.root.appending(path: "Example.app/Contents")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try Data().write(to: package.appending(path: "managed"))
        let linked = fixture.root.appending(path: "linked")
        try Data().write(to: linked)
        try fm.linkItem(at: linked, to: fixture.root.appending(path: "other-link"))
        let result = await Scanner.scan(plan: ScanPlan(folder: fixture.root)) { _ in }
        try #require(result.progress.state == .completed)
        let selected = try #require(result.nodes.first { $0.name == "selected" })
        let target = try #require(result.trashTarget(for: selected.id))
        #expect(target.scanID == result.id)
        let protected = result.nodes.filter { $0.id != selected.id && $0.parent != nil }
        #expect(
            Set(protected.map(\.name)) == [
                "folder", "link", "Example.app", "Contents", "managed", "linked", "other-link",
            ])
        for node in protected { #expect(result.trashTarget(for: node.id) == nil, "\(node.name)") }
        #expect(throws: CocoaError(.fileWriteNoPermission)) {
            try target.move { url in
                #expect(url == file)
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        #expect(try Data(contentsOf: file) == Data([1]))
        var calls: [URL] = []
        try target.move { calls.append($0) }
        #expect(calls == [file])
        let original = folder.appending(path: "original")
        try fm.moveItem(at: file, to: original)
        try Data([2]).write(to: file)
        #expect(throws: TrashTarget.Failure.changed) {
            try target.move { _ in Issue.record("Replacement was passed to Trash") }
        }
        #expect(try Data(contentsOf: file) == Data([2]))
        try fm.removeItem(at: file)
        try fm.createSymbolicLink(at: file, withDestinationURL: original)
        #expect(throws: TrashTarget.Failure.changed) {
            try target.move { _ in Issue.record("Link was passed to Trash") }
        }
        #expect(try fm.destinationOfSymbolicLink(atPath: file.path) == original.path)
        #expect(try Data(contentsOf: original) == Data([1]))
    }
}
