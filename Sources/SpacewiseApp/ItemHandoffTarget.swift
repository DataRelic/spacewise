import Darwin
import Foundation
import SpacewiseAppModel
import SpacewiseCore

/// One physical item in the settled scan. Finder reveal has its own path-only contract.
struct ItemHandoffTarget: Equatable {
    let url: URL
    let scanID: UUID
    private let node: ScanNode
    private let classification: ContentClassification

    init?(result: ScanResult, row: ScopeRow) {
        let id = row.node.id
        guard !result.namespace.isMerged(id), let url = result.url(for: id) else { return nil }
        self.url = url
        scanID = result.id
        node = row.node
        classification = row.classification
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scanID == rhs.scanID && lhs.node.id == rhs.node.id
    }

    enum Failure: Error, Equatable {
        case missing
        case changed
        case unavailable
        case restricted
        case refused

        func notice(for name: String) -> String {
            switch self {
            case .missing: ProductCopy.Inspector.itemMissing(name)
            case .changed: "“\(name)” changed since the scan. Rescan to refresh."
            case .unavailable: "“\(name)” is currently unavailable. Rescan to refresh."
            case .restricted: "“\(name)” is restricted for this action. You can show it in Finder."
            case .refused: "macOS couldn’t open “\(name)” with its default app."
            }
        }
    }

    var menuFacts: ItemFacts {
        let executable = node.kind == .file && (try? Self.readMetadata(url).get()).map(Self.hasExecuteBit) == true
        return ItemFacts(
            kind: node.kind, classification: classification, issue: node.issue, hasLocation: true,
            isExecutableFile: executable)
    }

    /// Check both the scan identity and the metadata used by the handoff policy. This is a metadata-only check.
    func currentFacts(
        read: (URL) -> Result<stat, Failure> = Self.readMetadata
    ) -> Result<ItemFacts, Failure> {
        // These entries were already inspection-only at scan time.
        guard node.issue == nil, node.kind != .symbolicLink, node.kind != .other else {
            return .failure(.restricted)
        }
        return read(url).flatMap { info in
            // An explicitly selected package root is scanned as an ordinary directory.
            let kind = MetadataPolicy.kind(mode: info.st_mode, extension: node.parent == nil ? "" : url.pathExtension)
            guard kind == node.kind, UInt64(info.st_ino) == node.inode else {
                return .failure(.changed)
            }
            guard let volume = Scanner.volumeIdentity(url) else { return .failure(.unavailable) }
            guard volume == node.device else { return .failure(.changed) }
            guard !MetadataPolicy.isPlaceholder(flags: info.st_flags) else { return .failure(.unavailable) }
            let accessMode = kind == .file ? R_OK : R_OK | X_OK
            guard faccessat(AT_FDCWD, url.path, accessMode, AT_EACCESS | AT_SYMLINK_NOFOLLOW) == 0 else {
                return .failure(.unavailable)
            }
            return .success(
                ItemFacts(
                    kind: kind, classification: classification, issue: nil, hasLocation: true,
                    isExecutableFile: kind == .file && Self.hasExecuteBit(info)))
        }
    }

    private static func hasExecuteBit(_ info: stat) -> Bool {
        info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
    }

    private static func readMetadata(_ url: URL) -> Result<stat, Failure> {
        var info = stat()
        // Reject ancestor symlink substitutions too. The scanner stores a resolved folder root.
        guard fstatat(AT_FDCWD, url.path, &info, AT_SYMLINK_NOFOLLOW_ANY) == 0 else {
            switch errno {
            case ENOENT: return .failure(.missing)
            case ELOOP, ENOTDIR, ESTALE: return .failure(.changed)
            default: return .failure(.unavailable)
            }
        }
        return .success(info)
    }
}
