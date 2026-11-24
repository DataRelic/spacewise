import Foundation
import Testing

@testable import SpacewiseCore

/// A startup drive shaped like real `diskutil` output on an Apple silicon Mac that boots from a sealed snapshot:
///
/// - `apfs list` names each container's volumes without saying where they are mounted.
/// - `info` reports `MountPoint`, as an empty string for an unmounted volume. There is no `Mounted` key.
/// - `apfs listSnapshots` refuses an unmounted volume, including the boot snapshot's own parent.
/// - `list` names the parent of a mounted snapshot.
///
/// Three containers: the boot container, one more on the same disk, and one on a mounted disk image.
private final class DriveFixture {
    static let bootPath = "/"
    static let dataPath = StartupDrive.dataVolumePath
    static let prebootPath = "/System/Volumes/iSCPreboot"
    static let swapPath = "/System/Volumes/VM"

    struct Volume {
        let device: String
        let mountPoint: String
        let store: String
        let uuid = UUID().uuidString
        var isSnapshot = false
    }

    let snapshotUUID = UUID().uuidString
    var volumes = [
        Volume(device: "disk3s1s1", mountPoint: bootPath, store: "disk0s2", isSnapshot: true),
        Volume(device: "disk1s1", mountPoint: prebootPath, store: "disk0s1"),
        Volume(device: "disk1s4", mountPoint: "", store: "disk0s1"),
        Volume(device: "disk3s1", mountPoint: "", store: "disk0s2"),
        Volume(device: "disk3s5", mountPoint: dataPath, store: "disk0s2"),
        Volume(device: "disk3s6", mountPoint: swapPath, store: "disk0s2"),
        Volume(device: "disk5s1", mountPoint: "/Library/Image", store: "disk4s1"),
    ]
    var containers = [
        ("disk1", "disk0s1", ["disk1s1", "disk1s4"]),
        ("disk3", "disk0s2", ["disk3s1", "disk3s5", "disk3s6"]),
        ("disk5", "disk4s1", ["disk5s1"]),
    ]
    let stores: [String: [String: Any]] = [
        "disk0s1": ["Internal": true, "ParentWholeDisk": "disk0", "MountPoint": ""],
        "disk0s2": ["Internal": true, "ParentWholeDisk": "disk0", "MountPoint": ""],
        "disk4s1": ["Internal": false, "ParentWholeDisk": "disk4", "MountPoint": ""],
    ]

    private(set) var queries: [[String]] = []
    /// Replaces the answer to one query: return `.some(nil)` for "no usable output", or throw.
    var override: (([String]) throws(MetadataToolError) -> [String: Any]??)?
    /// Whether `list` names the boot snapshot's parent.
    var listNamesSnapshotParent = true
    /// What the list entry of each volume claims its UUID is, when it should disagree with `info`.
    var listedUUIDs: [String: String] = [:]

    func queryCount(_ arguments: [String]) -> Int { queries.filter { $0 == arguments }.count }

    private func info(_ volume: Volume) -> [String: Any] {
        var detail: [String: Any] = [
            "MountPoint": volume.mountPoint, "DeviceIdentifier": volume.device,
            "VolumeUUID": volume.isSnapshot ? snapshotUUID : volume.uuid,
            "Internal": stores[volume.store]?["Internal"] as? Bool ?? false, "FilesystemType": "apfs",
            "APFSSnapshot": volume.isSnapshot, "APFSPhysicalStores": [["APFSPhysicalStore": volume.store]],
        ]
        if volume.isSnapshot { detail["APFSSnapshotUUID"] = snapshotUUID }
        return detail
    }

    func plist(_ arguments: [String]) throws(MetadataToolError) -> [String: Any]? {
        queries.append(arguments)
        if let replaced = try override?(arguments) { return replaced }
        switch arguments {
        case ["apfs", "list", "-plist"]:
            return [
                "Containers": containers.map { reference, store, devices in
                    [
                        "ContainerReference": reference,
                        "PhysicalStores": [["DeviceIdentifier": store]],
                        "Volumes": devices.map { device in
                            let uuid = listedUUIDs[device] ?? volumes.first { $0.device == device }!.uuid
                            return ["DeviceIdentifier": device, "APFSVolumeUUID": uuid]
                        },
                    ] as [String: Any]
                }
            ]
        case ["list", "-plist"]:
            let parent: [String: Any] = [
                "DeviceIdentifier": "disk3s1",
                "MountedSnapshots": listNamesSnapshotParent ? [["SnapshotUUID": snapshotUUID]] : [],
            ]
            return ["AllDisksAndPartitions": [["DeviceIdentifier": "disk3", "APFSVolumes": [parent]]]]
        default: break
        }
        if arguments.count == 4, arguments[0] == "apfs", arguments[1] == "listSnapshots" {
            guard let volume = volumes.first(where: { $0.device == arguments[2] }), !volume.mountPoint.isEmpty else {
                throw .nonzeroExit(status: 1)
            }
            return ["Snapshots": []]
        }
        guard arguments.count == 3, arguments[0] == "info" else { return nil }
        if let store = stores[arguments[2]] { return store }
        return volumes.first { $0.device == arguments[2] || (!$0.mountPoint.isEmpty && $0.mountPoint == arguments[2]) }
            .map(info)
    }

    /// Mount points whose identity cannot be read.
    var unidentifiable: Set<String> = []

    func identity(_ path: String) -> (UInt64, String)? {
        if unidentifiable.contains(path) { return nil }
        return volumes.firstIndex { $0.mountPoint == path }.map { (UInt64($0 + 1), "/dev/" + volumes[$0].device) }
    }

    func discover() -> DriveDiscovery {
        DriveDiscovery.discover(
            plist: { arguments throws(MetadataToolError) in try self.plist(arguments) }, identity: identity)
    }
}

private func unmounted(_ result: DriveDiscovery) -> [String] {
    result.reasons.compactMap { if case .unmounted(let device) = $0 { device } else { nil } }
}

private func unresolvedLocations(_ result: DriveDiscovery) -> [String?] {
    result.reasons.compactMap { if case .unresolved(_, let location) = $0 { .some(location) } else { nil } }
}

struct StartupDriveShapeTests {
    @Test func mountedVolumesAreAdmittedAndUnmountedOnesAreReportedQuietly() {
        let drive = DriveFixture()
        let result = drive.discover()
        #expect(
            result.roots.map(\.path) == [
                DriveFixture.bootPath, DriveFixture.dataPath, DriveFixture.prebootPath, DriveFixture.swapPath,
            ])
        // The boot snapshot's parent is unmounted too, but it is what `/` shows.
        #expect(unmounted(result) == ["disk1s4"])
        #expect(result.unresolved.isEmpty)
    }

    @Test func eachQueryIsMadeNoMoreOftenThanItsEvidenceNeeds() {
        let drive = DriveFixture()
        _ = drive.discover()
        for store in drive.stores.keys { #expect(drive.queryCount(["info", "-plist", store]) == 1) }
        // An unmounted volume has no snapshots to list and no mount to identify.
        #expect(drive.queryCount(["apfs", "listSnapshots", "disk1s4", "-plist"]) == 0)
        #expect(drive.queryCount(["apfs", "listSnapshots", "disk3s1", "-plist"]) == 0)
        // The Data volume was admitted by path, and the disk image is not on the startup disk.
        #expect(drive.queryCount(["info", "-plist", "disk3s5"]) == 0)
        #expect(drive.queryCount(["info", "-plist", "disk5s1"]) == 0)
        #expect(drive.queryCount(["list", "-plist"]) == 1)
        #expect(drive.queries.count == 17)
    }

    @Test(arguments: ["notNamed", "noOutput", "toolFailure"])
    func aSnapshotParentTheToolDoesNotNameIsReportedAsUnmounted(_ scenario: String) {
        let drive = DriveFixture()
        switch scenario {
        case "notNamed": drive.listNamesSnapshotParent = false
        case "noOutput":
            drive.override = { arguments throws(MetadataToolError) in
                arguments == ["list", "-plist"] ? .some(nil) : nil
            }
        default:
            drive.override = { arguments throws(MetadataToolError) in
                if arguments == ["list", "-plist"] { throw .nonzeroExit(status: 1) }
                return nil
            }
        }
        let result = drive.discover()
        #expect(result.roots.count == 4)
        #expect(unmounted(result) == ["disk1s4", "disk3s1"])
        #expect(result.unresolved.isEmpty)
        #expect(drive.queryCount(["list", "-plist"]) == 1)
    }

    @Test func aMacNotBootedFromASnapshotAsksForNoSnapshotEvidence() {
        let drive = DriveFixture()
        drive.volumes[0] = DriveFixture.Volume(device: "disk3s1", mountPoint: DriveFixture.bootPath, store: "disk0s2")
        drive.volumes.remove(at: 3)
        let result = drive.discover()
        #expect(result.roots.count == 4)
        #expect(unmounted(result) == ["disk1s4"])
        #expect(result.unresolved.isEmpty)
        #expect(drive.queries.allSatisfy { $0 != ["list", "-plist"] && !$0.contains("listSnapshots") })
        // The boot volume is in its container's list and was already admitted.
        #expect(drive.queryCount(["info", "-plist", "disk3s1"]) == 0)
    }

    @Test(arguments: ["/Volumes/Work", "/nix", "/System/Volumes/Update/mnt1", "/System/Volumes/Data/Users/Shared/Work"])
    func aVolumeMountedOutsideTheSystemVolumesFolderIsLeftToTheTraversal(_ mountPoint: String) {
        let drive = DriveFixture()
        drive.volumes.append(DriveFixture.Volume(device: "disk3s7", mountPoint: mountPoint, store: "disk0s2"))
        drive.containers[1].2.append("disk3s7")
        let result = drive.discover()
        #expect(result.roots.count == 4)
        #expect(!result.roots.map(\.path).contains(mountPoint))
        #expect(unmounted(result) == ["disk1s4"])
        #expect(result.unresolved.isEmpty)
        #expect(drive.queryCount(["apfs", "listSnapshots", "disk3s7", "-plist"]) == 0)
    }

    @Test func aVolumeAlreadyReportedAtItsMountPointIsNotJudgedTwice() {
        let drive = DriveFixture()
        // The Data volume's identity cannot be read, so the first attempt to admit it by path is recorded.
        let dataIndex = drive.volumes.firstIndex { $0.mountPoint == DriveFixture.dataPath }!
        drive.unidentifiable = [DriveFixture.dataPath]
        let result = drive.discover()
        #expect(!result.roots.map(\.path).contains(DriveFixture.dataPath))
        #expect(unresolvedLocations(result) == [DriveFixture.dataPath])
        #expect(drive.queryCount(["apfs", "listSnapshots", drive.volumes[dataIndex].device, "-plist"]) == 0)
    }

    @Test func aMountedVolumeWhoseSnapshotsCannotBeListedStaysUnverified() {
        let drive = DriveFixture()
        drive.override = { arguments throws(MetadataToolError) in
            if arguments == ["apfs", "listSnapshots", "disk3s6", "-plist"] { throw .nonzeroExit(status: 1) }
            return nil
        }
        let result = drive.discover()
        #expect(!result.roots.map(\.path).contains(DriveFixture.swapPath))
        #expect(result.roots.count == 3)
        #expect(unresolvedLocations(result) == ["/dev/disk3s6"])
    }

    @Test(arguments: ["missingMountPoint", "malformedMountPoint", "otherDevice", "listedUUIDDiffers"])
    func volumeEvidenceThatDoesNotAgreeIsUnverifiedNotUnmounted(_ scenario: String) {
        let drive = DriveFixture()
        if scenario == "listedUUIDDiffers" {
            drive.listedUUIDs["disk1s4"] = UUID().uuidString
        } else {
            drive.override = { arguments throws(MetadataToolError) in
                guard arguments == ["info", "-plist", "disk1s4"] else { return nil }
                var detail: [String: Any] = [
                    "MountPoint": "", "DeviceIdentifier": "disk1s4", "VolumeUUID": drive.volumes[2].uuid,
                    "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s1"]],
                ]
                switch scenario {
                case "missingMountPoint": detail.removeValue(forKey: "MountPoint")
                case "malformedMountPoint": detail["MountPoint"] = false
                default: detail["DeviceIdentifier"] = "disk9s9"
                }
                return detail
            }
        }
        let result = drive.discover()
        #expect(result.roots.count == 4)
        #expect(unmounted(result).isEmpty)
        #expect(unresolvedLocations(result) == ["/dev/disk1s4"])
    }

    @Test func queriesThatFailPartWayKeepWhatWasVerifiedAndReportTheRest() {
        let drive = DriveFixture()
        // The boot and Data volumes are admitted in the first six queries. Everything after that times out.
        drive.override = { arguments throws(MetadataToolError) in
            if drive.queries.count > 6 { throw .deadlineExceeded }
            return nil
        }
        let result = drive.discover()
        #expect(result.roots.map(\.path) == [DriveFixture.bootPath, DriveFixture.dataPath])
        #expect(unmounted(result).isEmpty)
        #expect(!result.reasons.contains { $0.isCancelled })
        // The other container on the startup disk, the two unadmitted volumes in the boot container, and the disk
        // image's container, whose store could not be asked about either.
        #expect(unresolvedLocations(result) == ["/dev/disk0s1", "/dev/disk3s1", "/dev/disk3s6", "/dev/disk4s1"])
    }
}

struct AdmittedVolumePolicyTests {
    private let policy = ScanPolicy(alsoExcluding: ["/System/Volumes/Preboot/excluded"])

    @Test func otherVolumeRulesStopAtAnAdmittedVolume() {
        for path in ["/System/Volumes/Preboot/boot", "/Volumes/Work/project"] {
            #expect(policy.exclusion(for: path, withinSelectedMount: nil) != nil)
            #expect(policy.exclusion(for: path, withinSelectedMount: nil, insideAdmittedVolume: true) == nil)
        }
    }

    @Test func cryptexGraftsAndOtherRulesStillApplyInsideAnAdmittedVolume() {
        for path in [
            ScanPolicy.cryptexGraftsPath, ScanPolicy.cryptexGraftsPath + "/OS/System", "/dev",
            "/System/Volumes/Preboot/excluded/folder",
        ] {
            #expect(policy.exclusion(for: path, withinSelectedMount: nil, insideAdmittedVolume: true) != nil)
        }
        // A sibling that only shares the prefix is not a graft.
        #expect(
            policy.exclusion(
                for: ScanPolicy.cryptexGraftsPath + "Backup", withinSelectedMount: nil, insideAdmittedVolume: true)
                == nil)
    }
}
