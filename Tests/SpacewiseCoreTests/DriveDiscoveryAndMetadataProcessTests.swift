import Darwin
import Foundation
import Testing

@testable import SpacewiseCore

/// The failure a run throws, or nil when it returned output.
private func metadataFailure(
    _ executable: String, _ arguments: [String], deadline: Date = Date().addingTimeInterval(5), limit: Int = 2_097_152
) -> MetadataToolError? {
    do {
        _ = try BoundedMetadataProcess.run(
            executable: executable, arguments: arguments, deadline: deadline, limit: limit)
        return nil
    } catch { return error }
}

struct MetadataProcessTests {
    @Test func returnsBoundedOutput() throws {
        #expect(
            try BoundedMetadataProcess.run(executable: "/usr/bin/printf", arguments: ["hello"], limit: 5)
                == Data("hello".utf8))
    }
    @Test func oversizedOutputIsReportedAsTheLimit() {
        let error = metadataFailure("/usr/bin/printf", ["oversized"], limit: 3)
        guard case .outputLimitExceeded(let limit)? = error else {
            Issue.record("expected outputLimitExceeded, got \(String(describing: error))")
            return
        }
        #expect(limit == 3)
    }
    @Test func nonzeroExitCarriesTheStatus() {
        let error = metadataFailure("/usr/bin/false", [])
        guard case .nonzeroExit(let status)? = error else {
            Issue.record("expected nonzeroExit, got \(String(describing: error))")
            return
        }
        #expect(status == 1)
    }
    @Test func spawnFailureCarriesTheUnderlyingError() {
        let missing = "/nonexistent/spacewise-test-tool"
        let error = metadataFailure(missing, [])
        guard case .spawnFailed(let executable, let underlying)? = error else {
            Issue.record("expected spawnFailed, got \(String(describing: error))")
            return
        }
        #expect(executable == missing)
        #expect((underlying as NSError).domain == NSCocoaErrorDomain)
    }
    @Test func nonPositiveLimitIsInvalid() {
        let error = metadataFailure("/usr/bin/true", [], limit: 0)
        guard case .invalidLimit(let limit)? = error else {
            Issue.record("expected invalidLimit, got \(String(describing: error))")
            return
        }
        #expect(limit == 0)
    }
    @Test func cancellationAndDeadlineCanPreventSpawn() async {
        let missing = "/nonexistent/spacewise-test-tool"
        let expired = metadataFailure(missing, [], deadline: Date().addingTimeInterval(-1))
        #expect(expired?.logCode == "deadlineExceeded")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return metadataFailure(missing, [])
        }
        #expect(await task.value?.logCode == "cancelled")
    }

    @Test func deadlineTerminatesAndReapsStartedChild() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ready = fixture.root.appending(path: "ready")
        let error = runSignallingChild(ready: ready, deadline: Date().addingTimeInterval(2))
        #expect(error?.logCode == "deadlineExceeded")
        let pid = try #require(childPID(at: ready), "The deadline must expire after child startup")
        expectReaped(pid)
    }

    @Test func cancellationTerminatesAndReapsRunningChild() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ready = fixture.root.appending(path: "ready")
        let task = Task.detached { runSignallingChild(ready: ready, deadline: Date().addingTimeInterval(10)) }
        // Wait for the child's signal with a bounded poll. The child keeps stdout open until it exits.
        let clock = ContinuousClock()
        let startupDeadline = clock.now + .seconds(5)
        var pid = childPID(at: ready)
        while pid == nil && clock.now < startupDeadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
            pid = childPID(at: ready)
        }
        if let pid { #expect(kill(pid, 0) == 0, "The child must still be running when cancellation is requested") }
        task.cancel()
        let error = await task.value
        #expect(error?.logCode == "cancelled")
        expectReaped(try #require(pid, "The child must signal before cancellation"))
    }

    private func runSignallingChild(ready: URL, deadline: Date) -> MetadataToolError? {
        // Publish a whole PID in one write, then replace the shell with sleep in the same PID.
        metadataFailure(
            "/bin/sh",
            ["-c", #"printf '%s\n' "$$" > "$1" || exit 1; exec /bin/sleep 30"#, "spacewise-test", ready.path],
            deadline: deadline)
    }

    private func childPID(at ready: URL) -> pid_t? {
        guard let text = try? String(contentsOf: ready, encoding: .utf8), text.last == "\n",
            let pid = pid_t(text.dropLast()), pid > 0
        else { return nil }
        return pid
    }

    private func expectReaped(_ pid: pid_t) {
        let status = kill(pid, 0)
        let code = errno
        #expect(status == -1 && code == ESRCH, "Child \(pid) must be gone, including its process table entry")
    }

    @Test func failureDescriptionsNameTheCause() {
        #expect(MetadataToolError.nonzeroExit(status: 3).description.contains("3"))
        #expect(MetadataToolError.deadlineExceeded.description.contains("deadline"))
        #expect(MetadataToolError.cancelled.isCancellation)
        #expect(!MetadataToolError.deadlineExceeded.isCancellation)
    }
}

struct DiscoveryFailureDetailTests {
    @Test func toolFailureReachesTheUnresolvedDetail() {
        let result = DriveDiscovery.discover(
            plist: { _ throws(MetadataToolError) in throw .nonzeroExit(status: 7) }, identity: { _ in nil })
        #expect(result.unresolved.count == 1)
        #expect(result.unresolved.first?.contains("status 7") == true)
    }
    @Test func cancelledToolRunIsCancellation() {
        let result = DriveDiscovery.discover(
            plist: { _ throws(MetadataToolError) in throw .cancelled }, identity: { _ in nil })
        #expect(result.unresolved.isEmpty)
        #expect(result.reasons.contains { $0.isCancelled })
    }
}

struct DiscoveryIntegrationTests {
    @Test(arguments: ["disk0", "disk1"])
    func selectedMountMustShareStartupPhysicalDisk(selectedDisk: String) {
        let dataPath = StartupDrive.dataVolumePath
        let dataUUID = UUID()
        let selected = DriveDiscovery.discover(
            plist: { args in
                switch args {
                case ["info", "-plist", "/"]:
                    return ["APFSPhysicalStores": [["APFSPhysicalStore": "boot-store"]]]
                case ["info", "-plist", "boot-store"]:
                    return ["Internal": true, "ParentWholeDisk": "disk0"]
                case ["info", "-plist", dataPath]:
                    return [
                        "MountPoint": dataPath, "DeviceIdentifier": "disk3s5", "VolumeUUID": dataUUID.uuidString,
                        "Internal": true, "FilesystemType": "apfs", "APFSSnapshot": false,
                        "APFSPhysicalStores": [["APFSPhysicalStore": "selected-store"]],
                    ]
                case ["info", "-plist", "selected-store"]:
                    return ["Internal": true, "ParentWholeDisk": selectedDisk]
                default:
                    Issue.record("Unexpected discovery query: \(args)")
                    return nil
                }
            },
            identity: { path in
                #expect(path == dataPath)
                return (31, "/dev/disk3s5")
            }, selectedMount: dataPath)
        #expect(selected.evidence.map(\.fsid) == (selectedDisk == "disk0" ? [31] : []))
    }

    @Test func rolesAndReplacement() {
        let uuid = UUID().uuidString
        func detail(_ path: String, _ device: String) -> [String: Any] {
            [
                "MountPoint": path, "DeviceIdentifier": device, "VolumeUUID": uuid,
                "Internal": true, "FilesystemType": "apfs", "APFSSnapshot": false,
                "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]],
            ]
        }
        let boot = detail("/", "disk3s1")
        let result = DriveDiscovery.discover(
            plist: { args in
                if args == ["apfs", "list", "-plist"] { return ["Containers": []] }
                if args.last == "disk0s2" { return ["Internal": true, "ParentWholeDisk": "disk0"] }
                if args.last == "/" { return boot }
                return nil
            }, identity: { _ in (1, "/dev/replacement") })
        #expect(result.roots.isEmpty)
        #expect(!result.unresolved.isEmpty)
        let accepted = DriveDiscovery.discover(
            plist: { args in
                if args == ["apfs", "list", "-plist"] { return ["Containers": []] }
                if args.last == "disk0s2" { return ["Internal": true, "ParentWholeDisk": "disk0"] }
                if args.last == "/" { return boot }
                return nil
            }, identity: { _ in (1, "/dev/disk3s1") })
        #expect(accepted.evidence.count == 1)
        #expect(accepted.evidence.first?.uuid == UUID(uuidString: uuid))
    }
}

struct DiscoveryCancellationTests {
    private func isCancelled(_ reason: DiscoveryReason) -> Bool { if case .cancelled = reason { true } else { false } }

    @Test func cancelledTopologyQueryIsCancellationNotFailure() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            // A cancelled metadata process yields no plist, exactly as the real runner does.
            return DriveDiscovery.discover(plist: { _ in nil }, identity: { _ in nil })
        }
        let result = await task.value
        #expect(result.unresolved.isEmpty)
        #expect(result.reasons.contains(where: isCancelled))
    }

    @Test func cancelledDiscoveryRecordsNoCoverageIssue() async {
        var cancelled = DriveDiscovery(unresolved: [])
        cancelled.reasons = [.cancelled]
        let discovery = cancelled
        let result = await Scanner.scan(
            plan: ScanPlan(roots: [], startup: true), injectedDiscovery: { discovery }, injectedFailure: nil,
            update: { _ in })
        #expect(result.progress.state == .cancelled)
        #expect(result.progress.issues.isEmpty)
        #expect(result.coverage.events == 0)
    }
}

struct DiscoveryIssueLocationTests {
    enum SecondaryStore: CaseIterable {
        case noOutput, toolFailure, multiple, missingDisk, external, otherDisk, cancelled

        var isUnresolved: Bool {
            switch self {
            case .noOutput, .toolFailure, .multiple, .missingDisk: true
            case .external, .otherDisk, .cancelled: false
            }
        }
    }

    @Test(arguments: SecondaryStore.allCases)
    func secondaryContainerEvidenceReachesTheScan(_ secondary: SecondaryStore) async throws {
        let dataPath = StartupDrive.dataVolumePath
        func volume(_ path: String, device: String) -> [String: Any] {
            [
                "MountPoint": path, "DeviceIdentifier": device,
                "VolumeUUID": path == "/"
                    ? "00000000-0000-0000-0000-000000000001" : "00000000-0000-0000-0000-000000000002",
                "Internal": true, "FilesystemType": "apfs", "APFSSnapshot": false,
                "APFSPhysicalStores": [["APFSPhysicalStore": "boot-store"]],
            ]
        }
        let discovery = DriveDiscovery.discover(
            plist: { args throws(MetadataToolError) in
                switch args {
                case ["info", "-plist", "/"]: return volume("/", device: "system")
                case ["info", "-plist", dataPath]: return volume(dataPath, device: "data")
                case ["info", "-plist", "boot-store"]: return ["Internal": true, "ParentWholeDisk": "disk0"]
                case ["apfs", "list", "-plist"]:
                    let stores = secondary == .multiple ? ["second-store", "third-store"] : ["second-store"]
                    return [
                        "Containers": [
                            [
                                "ContainerReference": "disk5",
                                "PhysicalStores": stores.map { ["DeviceIdentifier": $0] },
                                "Volumes": [["DeviceIdentifier": "disk5s1"]],
                            ]
                        ]
                    ]
                case ["info", "-plist", "second-store"]:
                    switch secondary {
                    case .noOutput: return nil
                    case .toolFailure: throw .nonzeroExit(status: 7)
                    case .missingDisk: return ["Internal": true]
                    case .external: return ["Internal": false]
                    case .otherDisk: return ["Internal": true, "ParentWholeDisk": "disk1"]
                    case .cancelled: throw .cancelled
                    case .multiple:
                        Issue.record("An ambiguous container should be reported before querying either store")
                        return nil
                    }
                default:
                    Issue.record("Unexpected discovery query: \(args)")
                    return nil
                }
            }, identity: { $0 == "/" ? (1, "/dev/system") : (2, "/dev/data") })
        #expect(discovery.roots.map(\.path) == ["/", dataPath])
        #expect(discovery.reasons.contains(where: \.isCancelled) == (secondary == .cancelled))
        #expect(discovery.unresolved.count == (secondary.isUnresolved ? 1 : 0))

        let result = await Scanner.scan(
            plan: .internalDisk, injectedDiscovery: { discovery },
            injectedNodes: [
                ScanNode(id: 0, parent: nil, name: "/", kind: .directory, device: 1, inode: 1),
                ScanNode(id: 1, parent: nil, name: dataPath, kind: .directory, device: 2, inode: 1),
                ScanNode(id: 2, parent: 1, name: "sample", kind: .file, allocatedBytes: 4096, device: 2, inode: 2),
            ],
            injectedFailure: nil, update: { _ in })
        let banner = StatusPresentation.outcome(
            phase: .settled, progress: result.progress, scopeName: "Startup Disk", coverage: result.coverage)
        let details = ScanDetails.make(result.coverage)
        #expect(result.logicalSummary(parent: nil).allocatedBytes == 4096)
        if secondary.isUnresolved {
            let path = secondary == .multiple ? "/dev/disk5" : "/dev/second-store"
            #expect(result.progress.state == .limited)
            #expect(result.progress.issues == [.unresolvedVolume: 1])
            #expect(result.coverage.actionableEvents == 1)
            #expect(result.logicalSummary(parent: nil).allocationUnknown)
            #expect(banner?.kind == .couldNotReadAll && banner?.actions == [.coverageDetails, .rescan])
            #expect(banner?.title.contains("startup storage") == true)
            #expect(details.needsAttention && details.totalEvents == 1 && details.text.contains("couldn’t be verified"))
            #expect(result.coverage.records.map(\.path) == [path])
            #expect(ScanDetails.paths(result.coverage).contains(path))
            if secondary == .toolFailure { #expect(ScanDetails.paths(result.coverage).contains("status 7")) }
        } else {
            #expect(result.progress.issues.isEmpty && details.totalEvents == 0)
            #expect(result.progress.state == (secondary == .cancelled ? .cancelled : .completed))
            #expect(banner?.kind == (secondary == .cancelled ? .stopped : .complete))
        }
    }

    @Test func eachUnmountedVolumeIsRecordedAtItsOwnLocation() async {
        var offline = DriveDiscovery(unresolved: [])
        offline.reasons = [.unmounted("disk3s5"), .unmounted("disk3s6")]
        let discovery = offline
        let result = await Scanner.scan(
            plan: ScanPlan(roots: [], startup: true), injectedDiscovery: { discovery }, injectedFailure: nil,
            update: { _ in })
        let paths = result.coverage.records.filter { $0.reason == .unmounted }.map(\.path)
        #expect(paths == ["/dev/disk3s5", "/dev/disk3s6"])
        #expect(result.coverage.events == 2)
    }

    @Test func unresolvedVolumeIsRecordedAtItsMountPoint() async {
        var unverified = DriveDiscovery(unresolved: [])
        unverified.reasons = [
            .unresolved("Unverified or changed mounted volume: /System/Volumes/Data", location: "/System/Volumes/Data"),
            .unresolved("Missing or unverified mount evidence", location: "/dev/disk3s2"),
            .unresolved("Startup topology unavailable or multi-store", location: "/"),
        ]
        let discovery = unverified
        let result = await Scanner.scan(
            plan: ScanPlan(roots: [], startup: true), injectedDiscovery: { discovery }, injectedFailure: nil,
            update: { _ in })
        #expect(result.coverage.records.map(\.path) == ["/System/Volumes/Data", "/dev/disk3s2", "/"])
        #expect(result.progress.issues[.unresolvedVolume] == 3)
    }

    @Test func discoveryNamesTheVolumeItCouldNotVerify() {
        let uuid = UUID().uuidString
        let boot: [String: Any] = [
            "MountPoint": "/", "DeviceIdentifier": "disk3s1", "VolumeUUID": uuid, "Internal": true,
            "FilesystemType": "apfs", "APFSSnapshot": false, "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]],
        ]
        let result = DriveDiscovery.discover(
            plist: { args in
                if args == ["apfs", "list", "-plist"] { return ["Containers": []] }
                if args.last == "disk0s2" { return ["Internal": true, "ParentWholeDisk": "disk0"] }
                if args.last == "/" { return boot }
                return nil
            }, identity: { _ in (1, "/dev/replacement") })
        guard case .unresolved(_, let location)? = result.reasons.first else {
            Issue.record("expected an unresolved reason")
            return
        }
        #expect(location == "/")
    }
}

struct DiscoveryAcceptanceTests {
    @Test(arguments: [
        "valid", "missingUUID", "missingSnapshot", "external", "snapshot", "multiStore", "changedUUID", "changedSource",
        "changedFSID", "image", "missingFilesystem", "missingMount",
    ])
    func metadataEvidence(scenario: String) {
        let uuid = UUID().uuidString
        var reads = 0
        var identities = 0
        let result = DriveDiscovery.discover(
            plist: { args in
                if args == ["apfs", "list", "-plist"] { return ["Containers": []] }
                if args.last?.hasPrefix("store") == true { return ["Internal": true, "ParentWholeDisk": "disk0"] }
                guard args.last == "/" else { return nil }
                reads += 1
                var detail: [String: Any] = [
                    "MountPoint": "/", "DeviceIdentifier": "boot", "VolumeUUID": uuid,
                    "Internal": true, "FilesystemType": "apfs", "APFSSnapshot": false,
                    "APFSPhysicalStores": [["APFSPhysicalStore": "store"]],
                ]
                switch scenario {
                case "missingUUID": detail.removeValue(forKey: "VolumeUUID")
                case "missingSnapshot": detail.removeValue(forKey: "APFSSnapshot")
                case "external", "image": detail["Internal"] = false
                case "missingFilesystem": detail.removeValue(forKey: "FilesystemType")
                case "missingMount": detail.removeValue(forKey: "MountPoint")
                case "snapshot": detail["APFSSnapshot"] = true
                case "multiStore":
                    detail["APFSPhysicalStores"] = [["APFSPhysicalStore": "store"], ["APFSPhysicalStore": "other"]]
                case "changedUUID": if reads > 1 { detail["VolumeUUID"] = UUID().uuidString }
                default: break
                }
                return detail
            },
            identity: { _ in
                identities += 1
                return (
                    scenario == "changedFSID" && identities > 1 ? 2 : 1,
                    scenario == "changedSource" && identities > 1 ? "/dev/replaced" : "/dev/boot"
                )
            })
        #expect(result.roots.count == (scenario == "valid" ? 1 : 0))
        if scenario != "valid" { #expect(!result.unresolved.isEmpty) }
    }

    @Test func snapshotParentAndDistinctRoles() {
        let snapshot = UUID().uuidString
        let mount = "/System/Volumes/"
        let devices = ["parent", "otherSystem", "otherData"]
        let uuids = Dictionary(uniqueKeysWithValues: devices.map { ($0, UUID().uuidString) })
        func detail(_ device: String, _ path: String) -> [String: Any] {
            [
                "MountPoint": path, "DeviceIdentifier": device, "VolumeUUID": uuids[device] ?? snapshot,
                "Internal": true, "FilesystemType": "apfs", "APFSSnapshot": device == "boot",
                "APFSSnapshotUUID": snapshot, "APFSPhysicalStores": [["APFSPhysicalStore": "store"]],
            ]
        }
        let result = DriveDiscovery.discover(
            plist: { args in
                if args == ["apfs", "list", "-plist"] {
                    return [
                        "Containers": devices.enumerated().map { index, device in
                            [
                                "ContainerReference": "container\(index)",
                                "PhysicalStores": [["DeviceIdentifier": "store\(index)"]],
                                "Volumes": [
                                    [
                                        "DeviceIdentifier": device,
                                        "Roles": [device == "otherData" ? "Data" : "System"],
                                    ]
                                ],
                            ] as [String: Any]
                        }
                    ]
                }
                if args.first == "apfs" {
                    return ["Snapshots": args.contains("parent") ? [["SnapshotUUID": snapshot]] : []]
                }
                if args.last?.hasPrefix("store") == true { return ["Internal": true, "ParentWholeDisk": "disk0"] }
                if args.last == "/" { return detail("boot", "/") }
                guard let arg = args.last, let device = devices.first(where: { arg == $0 || arg == mount + $0 }) else {
                    return nil
                }
                return detail(device, mount + device)
            },
            identity: { path in
                let device = path == "/" ? "boot" : String(path.dropFirst(mount.count))
                return (UInt64((["boot"] + devices).firstIndex(of: device)! + 1), "/dev/" + device)
            })
        #expect(Set(result.roots.map(\.path)) == ["/", mount + "otherSystem", mount + "otherData"])
        #expect(result.unresolved.isEmpty)
    }
}

@Test(arguments: ["valid", "mismatch", "unresolved", "cancelled"])
func scannerDiscoveryAcceptance(scenario: String) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    try Data("owned".utf8).write(to: root.appendingPathComponent("entry"))
    let observed = try #require(DriveDiscovery.mountedIdentity(root.path))
    let evidence = DiscoveredRoot(
        url: root, fsid: scenario == "mismatch" ? observed.0 ^ 1 : observed.0,
        device: String(observed.1.dropFirst(5)), uuid: UUID(), disk: "fixture")
    let discovery = DriveDiscovery(
        evidence: [evidence], roots: [root], unresolved: scenario == "unresolved" ? ["fixture unresolved"] : [])
    let task = Task {
        if scenario == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
        return await Scanner.scan(
            plan: ScanPlan(roots: [root], startup: true), injectedDiscovery: { discovery }, injectedFailure: nil,
            update: { _ in })
    }
    let result = await task.value
    if scenario == "cancelled" {
        #expect(result.progress.state == .cancelled)
    } else if scenario == "mismatch" {
        #expect(result.nodes.isEmpty)
        #expect(result.coverage.records.contains { $0.reason == .interruptedVolume && $0.operation == .identity })
    } else {
        #expect(result.nodes.contains { $0.name == "entry" })
        if scenario == "unresolved" { #expect(result.progress.issues[.unresolvedVolume] == 1) }
    }
}
