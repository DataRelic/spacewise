import Foundation

/// How far the scanner got with listing one folder.
/// - `unopened`: discovered, not read yet. `partial`: being listed now. `enumerated`: listed to the end.
/// - `cancelled`: the scan stopped before the listing finished.
/// The other states are terminal and always accompany a node issue; the folder will not be read or retried:
/// - `openFailed`: it could not be opened, or was no longer the folder that was discovered.
/// - `skipped`: deliberately not opened (excluded by policy, on another volume, or a cloud placeholder).
/// - `listingFailed`: it was opened, but reading its entries failed part-way.
public enum DirectoryEnumeration: String, Sendable {
    case unopened, enumerated, partial, cancelled, openFailed, skipped, listingFailed
}
public enum CoverageOperation: String, Sendable {
    case selectRoot, resolveRoot, rootMetadata, rootVolume, placeholder, identity, open, fdopendir, readdir, fstatat
    case traverse, metadata
}
public struct CoverageRecord: Sendable {
    public let path: String
    public let nodeID: Int?
    public let parentID: Int?
    public let operation: CoverageOperation
    public let reason: CoverageIssue
    public let policyDetail: String?
    public var count: UInt64 = 1
    /// The raw errno behind the failure, when there was one. `reason` stays the coarse category.
    public var errnoCode: Int32? = nil
}
public struct LocationCoverage: Sendable {
    public let wholeDrive: Bool
    public private(set) var actionableEvents: UInt64 = 0
    public private(set) var reasonCounts: [CoverageIssue: UInt64] = [:]
    public let limit: Int
    public private(set) var events: UInt64 = 0
    public private(set) var records: [CoverageRecord] = []
    public private(set) var truncated = false
    public var retainedUniqueLocations: Int { Set(records.map(\.path)).count }
    /// Unknown after truncation, including when later events match retained records.
    public var exactUniqueLocations: Int? { truncated ? nil : retainedUniqueLocations }
    public var enumeration: [Int: DirectoryEnumeration] = [:]
    public init(limit: Int = 256, wholeDrive: Bool = false) {
        self.limit = max(0, limit)
        self.wholeDrive = wholeDrive
    }
    public mutating func record(
        path: String, nodeID: Int?, operation: CoverageOperation, reason: CoverageIssue,
        parentID: Int? = nil, policyDetail: String? = nil, errnoCode: Int32? = nil
    ) {
        events += 1
        reasonCounts[reason, default: 0] += 1
        let record = CoverageRecord(
            path: path, nodeID: nodeID, parentID: parentID, operation: operation, reason: reason,
            policyDetail: policyDetail, errnoCode: errnoCode)
        if record.severity(wholeDrive: wholeDrive) == .actionable { actionableEvents += 1 }
        if let index = records.firstIndex(where: {
            $0.path == path && $0.operation == operation && $0.reason == reason && $0.policyDetail == policyDetail
                && $0.errnoCode == errnoCode
        }) {
            records[index].count += 1
            return
        }
        guard records.count < limit else {
            truncated = true
            return
        }
        records.append(record)
    }
}

extension CoverageIssue {
    /// Limits the scan has on purpose: policy exclusions, volume boundaries, cloud placeholders and unmounted
    /// storage. They are reported, but never as something that needs attention. Denial is decided per record.
    public var isExpectedByDesign: Bool {
        switch self {
        case .policyExcluded, .volumeBoundary, .placeholder, .unmounted: true
        case .denied, .vanished, .metadata, .enumeration, .invalidRoot, .interruptedVolume, .unresolvedVolume: false
        }
    }
}

public enum CoverageSeverity: Sendable { case informational, actionable }
extension CoverageRecord {
    /// Only known OS-managed denial in a whole-drive traversal is expected. Selected targets stay actionable.
    public func severity(wholeDrive: Bool) -> CoverageSeverity {
        if reason.isExpectedByDesign { return .informational }
        if reason == .denied && wholeDrive && operation != .selectRoot && operation != .rootMetadata {
            if ScanPolicy().classification(for: path) == .systemManaged { return .informational }
        }
        return .actionable
    }
}
