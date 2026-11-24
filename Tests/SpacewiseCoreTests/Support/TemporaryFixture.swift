import Darwin
import Foundation
import Testing

@testable import SpacewiseCore

/// A directory the test creates and removes. Tests never scan anything outside one of these.
struct Fixture {
    let root: URL

    init(base: URL = FileManager.default.temporaryDirectory) throws {
        root = base.appending(path: "spacewise-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    /// Supply startup-volume evidence for tests of enumeration that do not exercise disk discovery.
    func startupDiscovery() throws -> DriveDiscovery {
        let volume = try #require(Scanner.volumeIdentity(root))
        let data = DiscoveredRoot(
            url: URL(fileURLWithPath: StartupDrive.dataVolumePath), fsid: volume,
            device: "disk3s5", uuid: UUID(), disk: "disk0")
        return DriveDiscovery(evidence: [data], roots: [data.url], unresolved: [])
    }

    /// Removes the directory and everything below it, including folders a test made unreadable with `chmod 0` and
    /// trees nested deeper than PATH_MAX, which no path-based call can reach.
    func remove() {
        chmod(root.path, 0o700)
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { return }
        Self.removeContents(of: directory)
        close(directory)
        rmdir(root.path)
    }

    private static func removeContents(of directory: Int32) {
        guard let stream = fdopendir(dup(directory)) else { return }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        closedir(stream)
        for name in names {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                unlinkat(directory, name, 0)
                continue
            }
            fchmodat(directory, name, 0o700, 0)
            let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if child >= 0 {
                removeContents(of: child)
                close(child)
            }
            unlinkat(directory, name, AT_REMOVEDIR)
        }
    }
}
