import Darwin
import Foundation

/// One eligible file from a settled scan. The UI retains this value through menu tracking and confirmation.
public struct TrashTarget: Sendable {
    public let url: URL
    public let scanID: UUID
    let node: ScanNode

    /// Limit writes to personal content in this user's home, including on the startup disk's Data alias.
    static func personalLocation(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = StartupDrive.logicalPath(url.path)
        let root = StartupDrive.logicalPath(home.path)
        guard path.hasPrefix(root + "/") else { return false }
        let parts = path.dropFirst(root.count + 1).split(separator: "/").map { $0.lowercased() }
        guard let first = parts.first, !["library", "applications", ".trash"].contains(first),
            !parts.contains(where: { MetadataPolicy.packageExtension(($0 as NSString).pathExtension) })
        else { return false }
        let protectedFolders = ["desktop", "documents", "downloads", "movies", "music", "pictures", "public"]
        return parts.count > 1 || !protectedFolders.contains(first)
    }

    static func protectedMetadata(_ info: stat) -> Bool {
        info.st_uid != getuid()
            || info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | SF_RESTRICTED | UF_APPEND | SF_APPEND) != 0
            || MetadataPolicy.isPlaceholder(flags: info.st_flags)
            || (info.st_mode & S_IFMT == S_IFREG && info.st_nlink != 1)
    }

    public enum Failure: LocalizedError {
        case changed
        public var errorDescription: String? {
            "The item changed or is protected. Refresh the scan before trying again."
        }
    }

    @discardableResult public func moveToTrash() throws -> URL? {
        var destination: NSURL?
        try move { try FileManager.default.trashItem(at: $0, resultingItemURL: &destination) }
        return destination as URL?
    }

    package func move(using trash: (URL) throws -> Void) throws {
        guard node.kind == .file else { throw Failure.changed }
        var info = stat()
        guard let canonical = realpath(url.path, nil) else { throw Failure.changed }
        defer { free(canonical) }
        guard String(cString: canonical).utf8.elementsEqual(url.path.utf8),
            Self.personalLocation(url), lstat(url.path, &info) == 0,
            info.st_mode & S_IFMT == S_IFREG,
            Scanner.volumeIdentity(url) == node.device, UInt64(info.st_ino) == node.inode,
            !Self.protectedMetadata(info)
        else { throw Failure.changed }
        try trash(url)
    }
}

extension ScanResult {
    public func trashTarget(for id: Int) -> TrashTarget? {
        guard progress.state == .completed || progress.state == .limited,
            !namespace.isMerged(id), let row = logicalRow(for: id),
            row.eligibility == .explicitSelectionAfterRevalidation, let url = url(for: id)
        else { return nil }
        return TrashTarget(url: url, scanID: self.id, node: row.node)
    }
}
