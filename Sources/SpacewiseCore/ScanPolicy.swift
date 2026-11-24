import Foundation

public enum ContentClassification: String, Sendable, CaseIterable {
    case personal, applicationManaged, developerManaged, systemManaged
}
public enum OperationEligibility: Sendable { case inspectionOnly, explicitSelectionAfterRevalidation }
public struct ScanPolicy: Sendable {
    /// Further folders to exclude. Tests only: they have no system folder they can exclude inside a temporary fixture.
    private let additionalExclusions: [String]
    private let mountedVolumesPath: String
    private static let currentHomeLibrary = homeLibraryComponents(FileManager.default.homeDirectoryForCurrentUser.path)
    private let homeLibraryComponents: [Substring]

    public init() { self.init(alsoExcluding: []) }

    init(alsoExcluding paths: [String], mountedVolumesPath: String = "/Volumes", homePath: String? = nil) {
        additionalExclusions = paths
        self.mountedVolumesPath = mountedVolumesPath
        homeLibraryComponents = homePath.map(Self.homeLibraryComponents) ?? Self.currentHomeLibrary
    }
    private static func homeLibraryComponents(_ homePath: String) -> [Substring] {
        StartupDrive.logicalPath(homePath).split(separator: "/") + ["Library"]
    }
    private func normalized(_ path: String) -> String { StartupDrive.logicalPath(path) }
    private func under(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    private func suffix(after prefix: String, in path: String) -> Substring? {
        guard let match = path.range(of: prefix, options: [.anchored, .caseInsensitive]),
            match.upperBound == path.endIndex || path[match.upperBound] == "/"
        else { return nil }
        return path[match.upperBound...]
    }

    // APFS mount paths can be reached through alternate casing and the writable Data volume's alias.
    private func mountedPath(_ path: String) -> String {
        guard let dataPath = suffix(after: StartupDrive.dataVolumePath, in: path),
            !dataPath.isEmpty
        else { return path }
        return String(dataPath)
    }
    func isMountedVolumeDescendant(_ path: String) -> Bool {
        suffix(after: mountedVolumesPath, in: mountedPath(path)).map { !$0.isEmpty } ?? false
    }
    func isWithinMountedPath(_ path: String, root: String) -> Bool {
        suffix(after: mountedPath(root), in: mountedPath(path)) != nil
    }
    func isSameMountedPath(_ path: String, as other: String) -> Bool {
        mountedPath(path).caseInsensitiveCompare(mountedPath(other)) == .orderedSame
    }
    public func exclusion(for path: String) -> String? {
        exclusion(for: path, withinSelectedMount: nil)
    }
    /// The Preboot volume's cryptex disk images are grafted into this folder. A graft is not a mount: its files share
    /// the volume's device and filesystem id, so no boundary check sees it.
    static let cryptexGraftsPath = "/System/Volumes/Preboot/Cryptexes"

    /// `insideAdmittedVolume` is true for a path inside a volume the startup-disk scan admitted as its own root. Such a
    /// volume is scanned where it is mounted, so the two rules that keep a scan out of other volumes do not apply.
    func exclusion(
        for path: String, withinSelectedMount selectedRoot: String?, insideAdmittedVolume: Bool = false
    ) -> String? {
        let logical = normalized(path)
        if under(logical, "/dev") { return "device filesystem" }
        if under(logical, Self.cryptexGraftsPath) { return "cryptex contents; the disk images are already counted" }
        if !insideAdmittedVolume {
            if suffix(after: mountedVolumesPath, in: mountedPath(logical)) != nil,
                !(selectedRoot.map { under(path, $0) } ?? false)
            {
                return "mounted volume"
            }
            if under(logical, "/System/Volumes") { return "auxiliary volume or alias" }
        }
        if additionalExclusions.contains(where: { under(logical, $0) }) { return "excluded by the caller" }
        return nil
    }
    public func classification(for path: String) -> ContentClassification {
        let path = normalized(path)
        let parts = path.split(separator: "/")
        let standardHomeLibrary = parts.count >= 3 && parts[0] == "Users" && parts[2] == "Library"
        let currentHomeLibrary = parts.starts(with: homeLibraryComponents)
        let homeDeveloper =
            (standardHomeLibrary && parts.dropFirst(3).first == "Developer")
            || (currentHomeLibrary && parts.dropFirst(homeLibraryComponents.count).first == "Developer")
        if homeDeveloper || under(path, "/Library/Developer") { return .developerManaged }
        if under(path, "/Library") || standardHomeLibrary || currentHomeLibrary || under(path, "/Applications") {
            return .applicationManaged
        }
        if under(path, "/System") || under(path, "/private") || under(path, "/usr") || under(path, "/bin")
            || under(path, "/sbin")
        {
            return .systemManaged
        }
        return .personal
    }
    public func eligibility(for path: String, kind: NodeKind = .file) -> OperationEligibility {
        guard kind == .file else { return .inspectionOnly }
        return classification(for: path) == .personal && exclusion(for: path) == nil
            ? .explicitSelectionAfterRevalidation
            : .inspectionOnly
    }
}

/// Identity is authoritative; filesystem type or mount path alone cannot admit a root.
struct SelectedVolumeMetadata: Sendable {
    let identity: UInt64
    let local: Bool
    let removable: Bool
    func allowed(in startupIdentities: Set<UInt64>) -> Bool { rejection(in: startupIdentities) == nil }
    /// Why the volume is refused, or nil when it is allowed.
    func rejection(in startupIdentities: Set<UInt64>) -> String? {
        if !local { return "network or non-local volume" }
        if removable { return "removable volume" }
        if !startupIdentities.contains(identity) { return "could not verify this volume is on the startup drive" }
        return nil
    }
}
