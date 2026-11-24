import Foundation

public enum NodeKind: String, Codable, Sendable { case directory, package, file, symbolicLink, other }
public enum CoverageIssue: String, Codable, Sendable, CaseIterable {
    case unmounted, policyExcluded, denied, vanished, metadata, enumeration, volumeBoundary, placeholder, invalidRoot
    case interruptedVolume, unresolvedVolume
}
public enum ScanState: String, Codable, Sendable { case scanning, completed, limited, cancelled, invalid }

/// IDs are stable only within this scan. Paths/names stay in memory, never in aggregate logs.
public struct ScanNode: Sendable, Codable {
    public var id: Int
    public var name: String
    public var logicalBytes: UInt64 = 0
    public var allocatedBytes: UInt64 = 0
    public var device: UInt64
    public var inode: UInt64
    public var parent: Int?
    public var hardLinkOwner: Int?
    public var kind: NodeKind
    public var issue: CoverageIssue?
    /// Whether scan-time metadata rules out Trash. Missing metadata also rules it out.
    var blocksTrash: Bool?
    public var allocationUnknown = false

    // Keep initialization independent of the storage order used to reduce padding.
    public init(
        id: Int, parent: Int?, name: String, kind: NodeKind,
        logicalBytes: UInt64 = 0, allocatedBytes: UInt64 = 0,
        allocationUnknown: Bool = false, hardLinkOwner: Int? = nil,
        issue: CoverageIssue? = nil, device: UInt64, inode: UInt64
    ) {
        self.id = id
        self.parent = parent
        self.name = name
        self.kind = kind
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.allocationUnknown = allocationUnknown
        self.hardLinkOwner = hardLinkOwner
        self.issue = issue
        self.device = device
        self.inode = inode
    }
}

extension ScanNode {
    /// The numeric size represented by a list cell. A positive partial folder total is a lower bound.
    public func listSize(logical: Bool) -> UInt64? {
        guard kind != .symbolicLink, hardLinkOwner == nil || hardLinkOwner == id else { return nil }
        let bytes = logical ? logicalBytes : allocatedBytes
        if logical && kind == .file && issue == .placeholder { return bytes }
        if kind == .directory || kind == .package {
            if issue != nil && issue != .enumeration { return nil }
            return (allocationUnknown || issue != nil) && bytes == 0 ? nil : bytes
        }
        return issue == nil && !allocationUnknown ? bytes : nil
    }

    var sizeIndexKey: SizeIndexKey {
        SizeIndexKey(id: id, name: name, bytes: listSize(logical: false))
    }

    /// Shared by both the physical child index and the merged namespace.
    func precedesInSizeIndex(_ other: ScanNode) -> Bool {
        sizeIndexKey.precedes(other.sizeIndexKey)
    }
}

struct SizeIndexKey {
    let id: Int
    let name: String
    let bytes: UInt64?

    func precedes(_ other: Self) -> Bool {
        if bytes != other.bytes {
            guard let bytes else { return false }
            guard let otherBytes = other.bytes else { return true }
            return bytes > otherBytes
        }
        return name != other.name ? name < other.name : id < other.id
    }
}

public struct ScanProgress: Sendable, Codable {
    public var entries: UInt64 = 0
    public var logicalBytes: UInt64 = 0
    public var allocatedBytes: UInt64 = 0
    public var hardLinks: UInt64 = 0
    public var symbolicLinks: UInt64 = 0
    public var issues: [CoverageIssue: UInt64] = [:]
    public var elapsedSeconds: Double = 0
    public var state: ScanState = .scanning
    public var cancelled: Bool { state == .cancelled }
    public var finished: Bool { state != .scanning }
    public init() {}
}

public struct VolumeContext: Sendable, Codable {
    public var capacity: Int64?
    /// Free space right now, not counting purgeable space macOS can release on demand.
    public var available: Int64?
    /// Free space for something the person asked for, purgeable space included: the figure Finder shows as available.
    public var availableForImportantUsage: Int64?
    public var scope: String
    public init(root: URL, scope: String) {
        // Capacity is optional context: a failed lookup leaves the figures nil, which means "unavailable", and must
        // not fail a scan.
        let values = try? root.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        capacity = values?.volumeTotalCapacity.map(Int64.init)
        available = values?.volumeAvailableCapacity.map(Int64.init)
        availableForImportantUsage = values?.volumeAvailableCapacityForImportantUsage
        self.scope = scope
    }
}

public struct ScanPlan: Sendable {
    public let roots: [URL]
    public let policy: ScanPolicy
    public let startup: Bool
    public init(folder: URL) {
        self.init(folder: folder, policy: ScanPolicy())
    }
    /// A folder scan under a policy with further exclusions (tests only).
    init(folder: URL, policy: ScanPolicy) {
        roots = [folder]
        startup = false
        self.policy = policy
    }
    /// Traverse sealed system and writable data volumes once each. Cross-device aliases are excluded.
    public static var internalDisk: ScanPlan {
        let data = URL(fileURLWithPath: StartupDrive.dataVolumePath, isDirectory: true)
        return ScanPlan(roots: [URL(fileURLWithPath: "/", isDirectory: true), data], startup: true)
    }
    init(roots: [URL], startup: Bool) {
        self.roots = roots
        self.startup = startup
        policy = ScanPolicy()
    }
}

/// The startup drive's fixed layout: the writable Data volume is mounted at `dataVolumePath` and firm-linked into /.
public enum StartupDrive {
    public static let dataVolumePath = "/System/Volumes/Data"
    /// The path a person recognizes for a physical path: Data-volume paths are shown rooted at /.
    public static func logicalPath(_ physical: String) -> String {
        if physical == dataVolumePath { return "/" }
        return physical.hasPrefix(dataVolumePath + "/") ? String(physical.dropFirst(dataVolumePath.count)) : physical
    }
}
