import Darwin
import Foundation

struct DiscoveredRoot: Sendable {
    let url: URL
    let fsid: UInt64
    let device: String
    let uuid: UUID
    let disk: String
}
public enum DiscoveryReason: Sendable {
    /// `location` is the mount point or device node of the volume concerned; nil when the failure is not about one
    /// volume.
    case unresolved(String, location: String? = nil)
    case unmounted(String)
    case cancelled
    var isCancelled: Bool { if case .cancelled = self { true } else { false } }
}
/// Topology evidence, not mount names, admits a volume. Multi-store mappings fail closed.
public struct DriveDiscovery: Sendable {
    public var reasons: [DiscoveryReason] = []
    var evidence: [DiscoveredRoot] = []
    public var roots: [URL] = []
    public var unresolved: [String] {
        reasons.compactMap {
            if case .unresolved(let detail, _) = $0 { return detail }
            return nil
        }
    }
    init(evidence: [DiscoveredRoot] = [], roots: [URL] = [], unresolved: [String]) {
        self.evidence = evidence
        self.roots = roots
        self.reasons = unresolved.map { DiscoveryReason.unresolved($0) }
    }
    /// How long one discovery pass may spend in metadata queries. A startup-disk pass makes about forty, at roughly a
    /// fifth of a second each, and one more for every mounted disk image. Queries past the deadline fail, which leaves
    /// their volumes unverified.
    static let queryBudgetSeconds: TimeInterval = 20

    static func discover(selectedMount: String? = nil) -> DriveDiscovery {
        let deadline = Date().addingTimeInterval(queryBudgetSeconds)
        let started = ContinuousClock.now
        let result = discover(
            plist: { arguments throws(MetadataToolError) in
                let data = try BoundedMetadataProcess.run(arguments: arguments, deadline: deadline)
                let parsed: Any
                do {
                    parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
                } catch {
                    throw .malformedOutput(underlying: error)
                }
                guard let dictionary = parsed as? [String: Any] else { throw .malformedOutput(underlying: nil) }
                return dictionary
            }, identity: mountedIdentity, selectedMount: selectedMount)
        let unmounted = result.reasons.filter { if case .unmounted = $0 { true } else { false } }.count
        let elapsedMs = Int((started.duration(to: .now).totalSeconds * 1000).rounded())
        SpacewiseLog.discovery.notice(
            """
            discovery finished roots=\(result.roots.count, privacy: .public) \
            unresolved=\(result.unresolved.count, privacy: .public) unmounted=\(unmounted, privacy: .public) \
            cancelled=\(result.reasons.contains(where: \.isCancelled), privacy: .public) \
            elapsedMs=\(elapsedMs, privacy: .public)
            """)
        return result
    }
    /// Whether `path` is a mount point directly inside /System/Volumes, where macOS mounts its own volumes.
    static func isSystemVolumeMount(_ path: String) -> Bool {
        let parent = "/System/Volumes/"
        guard path.hasPrefix(parent) else { return false }
        let name = path.dropFirst(parent.count)
        return !name.isEmpty && !name.contains("/")
    }
    static func mountedIdentity(_ path: String) -> (UInt64, String)? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let source = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
        return (Scanner.volumeIdentity(fs), source)
    }
    static func mountPoint(_ fs: inout statfs) -> String {
        withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
    }
    /// `plist` returns nil when the tool ran but reported nothing usable, and throws when it could not be run or
    /// read. A thrown failure is kept and appended to the detail of the next unresolved reason, so it reaches the
    /// coverage record.
    static func discover(
        plist: ([String]) throws(MetadataToolError) -> [String: Any]?,
        identity: (String) -> (UInt64, String)?,
        selectedMount: String? = nil
    ) -> DriveDiscovery {
        var result = DriveDiscovery(unresolved: [])
        var lastFailure: MetadataToolError?
        var cancelled = false
        func query(_ arguments: [String]) -> [String: Any]? {
            lastFailure = nil
            guard !Task.isCancelled, !cancelled else {
                markCancelled()
                return nil
            }
            do {
                return try plist(arguments)
            } catch {
                lastFailure = error
                // The arguments name devices and mount points, so only the failure's code is logged.
                if error.isCancellation {
                    markCancelled()
                    SpacewiseLog.discovery.notice("metadata query cancelled")
                } else {
                    SpacewiseLog.discovery.error(
                        """
                        metadata query failed code=\(error.logCode, privacy: .public) \
                        value=\(error.logValue, privacy: .public)
                        """)
                }
                return nil
            }
        }
        // A cancelled query returns no data, just as a failed one does. Report it as cancellation, not as a topology
        // failure.
        func markCancelled() {
            guard !cancelled else { return }
            cancelled = true
            result.reasons.append(.cancelled)
        }
        func unresolved(_ detail: String, location: String?) {
            let cause = lastFailure
            lastFailure = nil
            if Task.isCancelled || cancelled {
                markCancelled()
                return
            }
            result.reasons.append(
                .unresolved(
                    cause.map { "\(detail) (\($0.description))" } ?? detail,
                    location: location))
        }
        /// Admitted as a root, or already reported as unresolved at that location.
        func isAccountedFor(_ path: String) -> Bool {
            result.roots.contains { $0.path == path }
                || result.reasons.contains {
                    if case .unresolved(_, let location) = $0 { return location == path }
                    return false
                }
        }
        func deviceNode(_ volume: [String: Any]) -> String? {
            (volume["DeviceIdentifier"] as? String).map { "/dev/" + $0 }
        }
        // Which disk a physical store is a partition of cannot change within one pass, and every admitted volume asks
        // twice, so each store is queried once. Only an answer is kept: a failed query is asked again.
        var knownStores: [String: [String: Any]] = [:]
        func backingStore(_ store: String) -> [String: Any]? {
            if let known = knownStores[store] {
                lastFailure = nil
                return known
            }
            guard let detail = query(["info", "-plist", store]) else { return nil }
            knownStores[store] = detail
            return detail
        }
        func disk(_ detail: [String: Any]) -> String? {
            guard let stores = detail["APFSPhysicalStores"] as? [[String: Any]], stores.count == 1,
                let store = stores[0]["APFSPhysicalStore"] as? String,
                let backing = backingStore(store),
                backing["Internal"] as? Bool == true
            else { return nil }
            guard let disk = backing["ParentWholeDisk"] as? String, !disk.isEmpty else { return nil }
            return disk
        }
        guard let boot = query(["info", "-plist", "/"]), let startupDisk = disk(boot) else {
            unresolved("Startup topology unavailable or multi-store", location: "/")
            return result
        }
        // A snapshot UUID belongs to exactly one parent volume. Query membership rather than inferring it from a
        // device suffix or interpreting System/Data roles. A failed query leaves the parent relationship unknown.
        func isActiveSnapshotParent(_ volume: [String: Any]) -> Bool? {
            guard boot["APFSSnapshot"] as? Bool == true else { return false }
            guard let device = volume["DeviceIdentifier"] as? String,
                let snapshots = query(["apfs", "listSnapshots", device, "-plist"])?["Snapshots"] as? [[String: Any]],
                let activeUUID = boot["APFSSnapshotUUID"] as? String
            else {
                unresolved("Snapshot parent evidence unavailable", location: deviceNode(volume))
                return nil
            }
            return snapshots.contains { $0["SnapshotUUID"] as? String == activeUUID }
        }
        // The boot snapshot's parent volume is normally not mounted, and `listSnapshots` refuses an unmounted volume,
        // so the parent is found in `diskutil list` instead. Asked once, and only when an unmounted volume turns up.
        // No answer means the parent is reported like any other unmounted volume; nothing is admitted on this evidence.
        var snapshotParentDevice: String??
        func unmountedSnapshotParent() -> String? {
            if let known = snapshotParentDevice { return known }
            var found: String?
            if boot["APFSSnapshot"] as? Bool == true, let activeUUID = boot["APFSSnapshotUUID"] as? String,
                let disks = query(["list", "-plist"])?["AllDisksAndPartitions"] as? [[String: Any]]
            {
                found =
                    disks.lazy
                    .flatMap { $0["APFSVolumes"] as? [[String: Any]] ?? [] }
                    .first { volume in
                        (volume["MountedSnapshots"] as? [[String: Any]] ?? [])
                            .contains { $0["SnapshotUUID"] as? String == activeUUID }
                    }?["DeviceIdentifier"] as? String
            }
            lastFailure = nil
            snapshotParentDevice = .some(found)
            return found
        }
        func admit(_ path: String, _ detail: [String: Any], active: Bool = false) {
            lastFailure = nil
            guard detail["MountPoint"] as? String == path,
                detail["Internal"] as? Bool == true,
                detail["FilesystemType"] as? String == "apfs",
                let snapshot = detail["APFSSnapshot"] as? Bool,
                !snapshot
                    || (active && path == "/"
                        && (detail["APFSSnapshotUUID"] as? String).flatMap(UUID.init(uuidString:)) != nil),
                let device = detail["DeviceIdentifier"] as? String,
                let rawUUID = detail["VolumeUUID"] as? String, let uuid = UUID(uuidString: rawUUID),
                disk(detail) == startupDisk,
                let before = identity(path), before.1 == "/dev/" + device,
                let check = query(["info", "-plist", path]),
                check["DeviceIdentifier"] as? String == device,
                check["VolumeUUID"] as? String == rawUUID,
                check["APFSSnapshot"] as? Bool == snapshot,
                disk(check) == startupDisk,
                let after = identity(path), after == before
            else {
                unresolved("Unverified or changed mounted volume: " + path, location: path)
                return
            }
            guard !result.evidence.contains(where: { $0.fsid == before.0 || $0.uuid == uuid }) else { return }
            result.evidence.append(
                DiscoveredRoot(
                    url: URL(fileURLWithPath: path), fsid: before.0, device: device,
                    uuid: uuid, disk: startupDisk))
            result.roots.append(URL(fileURLWithPath: path))
        }
        if let selectedMount {
            if selectedMount == "/" {
                admit("/", boot, active: true)
            } else if let detail = query(["info", "-plist", selectedMount]) {
                if selectedMount == StartupDrive.dataVolumePath || isActiveSnapshotParent(detail) == false {
                    admit(selectedMount, detail)
                }
            } else {
                unresolved("Unverified or changed mounted volume: " + selectedMount, location: selectedMount)
            }
            return result
        }
        guard let topology = query(["apfs", "list", "-plist"]),
            let containers = topology["Containers"] as? [[String: Any]]
        else {
            unresolved("Startup topology unavailable or multi-store", location: "/")
            return result
        }
        admit("/", boot, active: true)
        // The Data volume is asked for by path first. If that query fails, the container walk below usually admits
        // or records the volume anyway; the failure is reported only if neither happens.
        lastFailure = nil
        var dataQueryFailure: MetadataToolError?
        if let data = query(["info", "-plist", StartupDrive.dataVolumePath]) {
            admit(StartupDrive.dataVolumePath, data)
        } else {
            dataQueryFailure = lastFailure
        }
        containers: for container in containers {
            guard !Task.isCancelled, !cancelled else {
                markCancelled()
                break
            }
            lastFailure = nil
            let containerLocation = (container["ContainerReference"] as? String).map { "/dev/" + $0 }
            guard let stores = container["PhysicalStores"] as? [[String: Any]], stores.count == 1,
                let store = stores[0]["DeviceIdentifier"] as? String, !store.isEmpty
            else {
                unresolved("APFS container has missing or ambiguous physical stores", location: containerLocation)
                continue
            }
            guard let backing = backingStore(store), let isInternal = backing["Internal"] as? Bool else {
                unresolved("Couldn’t verify the APFS container’s physical store", location: "/dev/" + store)
                continue
            }
            if !isInternal { continue }
            guard let wholeDisk = backing["ParentWholeDisk"] as? String, !wholeDisk.isEmpty else {
                unresolved("Couldn’t identify the disk behind the APFS container", location: "/dev/" + store)
                continue
            }
            if wholeDisk != startupDisk { continue }
            guard let volumes = container["Volumes"] as? [[String: Any]] else {
                unresolved("Couldn’t identify the APFS container’s volumes", location: containerLocation)
                continue
            }
            for volume in volumes {
                if Task.isCancelled || cancelled {
                    markCancelled()
                    break containers
                }
                lastFailure = nil
                guard let device = volume["DeviceIdentifier"] as? String, !device.isEmpty else {
                    unresolved("Missing or unverified mount evidence", location: containerLocation)
                    continue
                }
                // Active namespace aliases are deduplicated by evidence, never by role.
                if result.evidence.contains(where: { $0.device == device }) { continue }
                // `apfs list` names the container's volumes but not where they are mounted. `info` reports the mount
                // point, as an empty string for an unmounted volume. A missing mount point is an unknown shape, not
                // an unmounted volume.
                guard let detail = query(["info", "-plist", device]),
                    detail["DeviceIdentifier"] as? String == device,
                    let rawUUID = detail["VolumeUUID"] as? String, UUID(uuidString: rawUUID) != nil,
                    (volume["APFSVolumeUUID"] as? String).map({ $0 == rawUUID }) ?? true,
                    let mountPoint = detail["MountPoint"] as? String
                else {
                    unresolved("Missing or unverified mount evidence", location: "/dev/" + device)
                    continue
                }
                if mountPoint.isEmpty {
                    // The boot snapshot's parent is measured through the snapshot at `/`.
                    let snapshotParent = unmountedSnapshotParent()
                    if Task.isCancelled || cancelled {
                        markCancelled()
                        break containers
                    }
                    if device == snapshotParent { continue }
                    if disk(detail) == startupDisk {
                        result.reasons.append(.unmounted(device))
                    } else {
                        unresolved("Missing or unverified mount evidence", location: "/dev/" + device)
                    }
                    continue
                }
                // The walk adds macOS's own volumes, which it mounts directly under /System/Volumes. A volume someone
                // created on the same drive is left where the traversal meets it, as another volume: the unified tree
                // has no place for it except the group of items macOS manages, which it is not. This narrows what
                // identity may admit; a path never admits anything.
                guard Self.isSystemVolumeMount(mountPoint) else { continue }
                // A volume already admitted or already reported at this path is not judged a second time.
                if isAccountedFor(mountPoint) { continue }
                // Only a mounted volume can be asked for its snapshots. A mounted parent of the boot snapshot would
                // be the system volume a second time.
                guard isActiveSnapshotParent(detail) == false else { continue }
                admit(mountPoint, detail)
            }
        }
        if Task.isCancelled { markCancelled() }
        if let dataQueryFailure, !isAccountedFor(StartupDrive.dataVolumePath) {
            lastFailure = dataQueryFailure
            unresolved(
                "Unverified or changed mounted volume: " + StartupDrive.dataVolumePath,
                location: StartupDrive.dataVolumePath)
        }
        return result
    }
}
