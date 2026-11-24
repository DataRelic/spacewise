import Foundation
import Testing

@testable import SpacewiseCore

@Test func truncatedUnexpectedRemainsActionable() {
    var coverage = LocationCoverage(limit: 1, wholeDrive: true)
    coverage.record(path: "/dev", nodeID: nil, operation: .traverse, reason: .policyExcluded)
    coverage.record(path: "/Users/example", nodeID: nil, operation: .open, reason: .denied)
    #expect(coverage.truncated)
    #expect(coverage.actionableEvents == 1)
    #expect(coverage.events == 2)
}
@Test func expectedAndExplicitDenialsDiffer() {
    var drive = LocationCoverage(wholeDrive: true)
    drive.record(path: "/System/protected", nodeID: nil, operation: .traverse, reason: .denied)
    #expect(drive.actionableEvents == 0)
    var folder = LocationCoverage()
    folder.record(path: "/System/protected", nodeID: nil, operation: .selectRoot, reason: .denied)
    #expect(folder.actionableEvents == 1)
}

@Test(arguments: [
    CoverageOperation.traverse, .fdopendir, .readdir, .fstatat, .metadata, .selectRoot, .rootMetadata, .open,
])
func denialOperationSeverity(_ operation: CoverageOperation) {
    var coverage = LocationCoverage(limit: 0, wholeDrive: true)
    coverage.record(path: "/System/protected", nodeID: nil, operation: operation, reason: .denied)
    #expect(coverage.actionableEvents == ([CoverageOperation.selectRoot, .rootMetadata].contains(operation) ? 1 : 0))
    #expect(coverage.truncated)
}

@Test(arguments: [
    ("/private/var/db/protected", true, UInt64(0)),
    ("/System/Volumes/Data/private/var/db/protected", true, 0),
    ("/System/Volumes/Data/Users/example/Library/protected", true, 1),
    ("/private-project/protected", true, 1),
    ("/private/var/db/protected", false, 1),
])
func directoryOpenDenialDependsOnLocationAndScanScope(_ path: String, _ wholeDrive: Bool, _ actionable: UInt64) {
    var coverage = LocationCoverage(limit: 0, wholeDrive: wholeDrive)
    coverage.record(path: path, nodeID: nil, operation: .open, reason: .denied, errnoCode: EPERM)
    #expect(coverage.actionableEvents == actionable)
    #expect(coverage.reasonCounts[.denied] == 1)
    #expect(ScanDetails.make(coverage).deniedNeedingAttention == actionable)
}

@Test func neutralUnknownAndMixedWarning() {
    var progress = ScanProgress()
    progress.state = .limited
    var coverage = LocationCoverage(limit: 0, wholeDrive: true)
    coverage.record(path: "/dev/disk1s4", nodeID: nil, operation: .rootVolume, reason: .unmounted)
    #expect(
        StatusPresentation.outcome(phase: .settled, progress: progress, scopeName: "fixture", coverage: coverage)?.tone
            == .neutral)
    coverage.record(path: "/", nodeID: nil, operation: .identity, reason: .interruptedVolume)
    #expect(
        StatusPresentation.outcome(phase: .settled, progress: progress, scopeName: "fixture", coverage: coverage)?.tone
            == .caution)
    #expect(coverage.actionableEvents == 1)
    #expect(coverage.reasonCounts[.unmounted] == 1)
}

@Test(arguments: [
    "unmounted", "lockedUnmounted", "lockedUnknown", "missingMountPoint", "missingUUID", "missingDevice",
    "missingBacking",
    "wrongDisk", "malformed", "unavailable",
])
func unmountedDiscoveryMatrix(_ scenario: String) async {
    let uuid = UUID().uuidString
    var identityPaths: [String] = []
    let discovery = DriveDiscovery.discover(
        plist: { args in
            if args == ["apfs", "list", "-plist"] {
                return [
                    "Containers": [
                        [
                            "PhysicalStores": [["DeviceIdentifier": "store"]],
                            "Volumes": [["DeviceIdentifier": "offline"]],
                        ]
                    ]
                ]
            }
            if args.last == "store" { return ["Internal": true, "ParentWholeDisk": "disk0"] }
            if args.last == "other" { return ["Internal": true, "ParentWholeDisk": "disk1"] }
            if args.last == "/" { return ["APFSPhysicalStores": [["APFSPhysicalStore": "store"]]] }
            guard args.last == "offline", scenario != "unavailable" else { return nil }
            var value: [String: Any] = [
                "MountPoint": "", "DeviceIdentifier": "offline", "VolumeUUID": uuid,
                "APFSPhysicalStores": [["APFSPhysicalStore": "store"]],
            ]
            switch scenario {
            case "lockedUnmounted": value["Locked"] = true
            case "lockedUnknown":
                value["Locked"] = true
                value.removeValue(forKey: "MountPoint")
            case "missingMountPoint": value.removeValue(forKey: "MountPoint")
            case "missingUUID": value.removeValue(forKey: "VolumeUUID")
            case "missingDevice": value.removeValue(forKey: "DeviceIdentifier")
            case "missingBacking": value.removeValue(forKey: "APFSPhysicalStores")
            case "wrongDisk": value["APFSPhysicalStores"] = [["APFSPhysicalStore": "other"]]
            case "malformed": value["MountPoint"] = false
            default: break
            }
            return value
        },
        identity: { path in
            identityPaths.append(path)
            return nil
        })
    #expect(identityPaths.isEmpty)
    #expect(discovery.roots.isEmpty)
    let offline = discovery.reasons.filter { if case .unmounted = $0 { true } else { false } }.count
    #expect(offline == (["unmounted", "lockedUnmounted"].contains(scenario) ? 1 : 0))
    let result = await Scanner.scan(
        plan: ScanPlan(roots: [], startup: true), injectedDiscovery: { discovery }, injectedFailure: nil,
        update: { _ in })
    #expect(result.nodes.isEmpty)
    #expect(result.progress.issues[.unmounted, default: 0] == UInt64(offline))
    #expect(result.coverage.reasonCounts[.unmounted, default: 0] == UInt64(offline))
    // Boot intentionally lacks admission evidence: one actionable event, plus any offline verification gap.
    #expect(result.coverage.actionableEvents == (["unmounted", "lockedUnmounted"].contains(scenario) ? 1 : 2))
}
