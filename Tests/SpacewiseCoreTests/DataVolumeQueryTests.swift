import Foundation
import Synchronization
import Testing

@testable import SpacewiseCore

/// Discovery asks for the Data volume by path before walking the containers. When that query fails and the Data
/// volume is then never admitted, the gap must be recorded; when the container walk admits or records it anyway,
/// nothing more is added.
struct DataVolumeQueryTests {
    private let bootUUID = UUID().uuidString
    private let dataUUID = UUID().uuidString

    private var boot: [String: Any] {
        [
            "MountPoint": "/", "DeviceIdentifier": "disk3s1", "VolumeUUID": bootUUID, "Internal": true,
            "FilesystemType": "apfs", "APFSSnapshot": false, "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]],
        ]
    }
    private var data: [String: Any] {
        [
            "MountPoint": StartupDrive.dataVolumePath, "DeviceIdentifier": "disk3s5", "VolumeUUID": dataUUID,
            "Internal": true, "FilesystemType": "apfs", "APFSSnapshot": false,
            "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]],
        ]
    }
    /// One container on the startup disk, listing the Data volume, or no containers at all.
    private func topology(listsData: Bool) -> [String: Any] {
        guard listsData else { return ["Containers": []] }
        return [
            "Containers": [
                [
                    "PhysicalStores": [["DeviceIdentifier": "disk0s2"]],
                    "Volumes": [["DeviceIdentifier": "disk3s5"]],
                ]
            ]
        ]
    }
    private func identity(_ path: String) -> (UInt64, String)? {
        path == "/" ? (1, "/dev/disk3s1") : (2, "/dev/disk3s5")
    }
    private func dataReasons(_ result: DriveDiscovery) -> [String] {
        result.reasons.compactMap {
            if case .unresolved(let detail, let location) = $0, location == StartupDrive.dataVolumePath {
                return detail
            }
            return nil
        }
    }

    @Test func failedQueryIsRecordedWhenTheDataVolumeIsNeverAdmitted() {
        let topology = topology(listsData: false)
        let boot = boot
        let result = DriveDiscovery.discover(
            plist: { args throws(MetadataToolError) in
                if args == ["apfs", "list", "-plist"] { return topology }
                switch args.last {
                case "/": return boot
                case "disk0s2": return ["Internal": true, "ParentWholeDisk": "disk0"]
                case StartupDrive.dataVolumePath: throw .nonzeroExit(status: 7)
                default: return nil
                }
            }, identity: identity)
        #expect(result.roots.map(\.path) == ["/"])
        let details = dataReasons(result)
        #expect(details.count == 1)
        #expect(details.first?.contains("status 7") == true, "the cause reaches the record: \(details)")
    }

    @Test func aFailedQueryThatTheContainerWalkRecoversFromIsNotAnIssue() {
        let topology = topology(listsData: true)
        let boot = boot
        let data = data
        let pathQueries = Mutex(0)
        let result = DriveDiscovery.discover(
            plist: { args throws(MetadataToolError) in
                if args == ["apfs", "list", "-plist"] { return topology }
                switch args.last {
                case "/": return boot
                case "disk0s2": return ["Internal": true, "ParentWholeDisk": "disk0"]
                case "disk3s5": return data
                case StartupDrive.dataVolumePath:
                    // The first, early query fails; the container walk's own check later succeeds.
                    if pathQueries.withLock({
                        $0 += 1
                        return $0
                    }) == 1 {
                        throw .deadlineExceeded
                    }
                    return data
                default: return nil
                }
            }, identity: identity)
        #expect(Set(result.roots.map(\.path)) == ["/", StartupDrive.dataVolumePath])
        #expect(result.unresolved.isEmpty)
    }

    @Test func aDataVolumeTheContainerWalkAlreadyRecordedIsRecordedOnce() {
        let topology = topology(listsData: true)
        let boot = boot
        let data = data
        let result = DriveDiscovery.discover(
            plist: { args throws(MetadataToolError) in
                if args == ["apfs", "list", "-plist"] { return topology }
                switch args.last {
                case "/": return boot
                case "disk0s2": return ["Internal": true, "ParentWholeDisk": "disk0"]
                case "disk3s5": return data
                case StartupDrive.dataVolumePath: throw .nonzeroExit(status: 7)
                default: return nil
                }
            }, identity: identity)
        #expect(result.roots.map(\.path) == ["/"])
        #expect(dataReasons(result).count == 1)
    }

    @Test func theScanCountsTheRecordedGapAsUnresolvedStorage() async {
        var discovery = DriveDiscovery(unresolved: [])
        discovery.reasons = [
            .unresolved(
                "Unverified or changed mounted volume: /System/Volumes/Data (exited with status 7)",
                location: StartupDrive.dataVolumePath)
        ]
        let injected = discovery
        let result = await Scanner.scan(
            plan: ScanPlan(roots: [], startup: true), injectedDiscovery: { injected },
            injectedFailure: nil, update: { _ in })
        #expect(result.progress.issues[.unresolvedVolume] == 1)
        #expect(result.coverage.records.map(\.path) == [StartupDrive.dataVolumePath])
    }
}
