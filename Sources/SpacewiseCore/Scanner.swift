import Darwin
import Foundation

public enum Scanner {
    /// A file's filesystem identity. Hard links share one, so their bytes are counted once.
    struct Identity: Hashable {
        let device: UInt64
        let inode: UInt64
    }
    /// `statfs` could not identify a path's volume. Distinct from a path on a different volume.
    struct VolumeLookupFailure: Error {
        let errnoCode: Int32
    }
    /// The volume a path is on, or the errno `statfs` failed with. A failed lookup says nothing about which volume the
    /// path is on, so callers must not read it as "another volume".
    static func lookUpVolumeIdentity(_ url: URL) -> Result<UInt64, VolumeLookupFailure> {
        var value = statfs()
        guard statfs(url.path, &value) == 0 else { return .failure(VolumeLookupFailure(errnoCode: errno)) }
        return .success(volumeIdentity(value))
    }
    package static func volumeIdentity(_ url: URL) -> UInt64? {
        try? lookUpVolumeIdentity(url).get()
    }
    static func volumeIdentity(_ value: statfs) -> UInt64 {
        UInt64(UInt32(bitPattern: value.f_fsid.val.0)) << 32 | UInt64(UInt32(bitPattern: value.f_fsid.val.1))
    }
    static func failure(_ code: Int32) -> CoverageIssue {
        switch code {
        case EACCES, EPERM: .denied
        case ENOENT, ESTALE: .vanished
        default: .metadata
        }
    }
    /// One owned worker, one open directory at a time; metadata only. No contents or cloud requests.
    /// The terminal callbacks observe an already committed result. Cancelling in one of them cannot change it.
    @concurrent public static func scan(
        plan: ScanPlan,
        diagnostics: (@Sendable (ScanMemorySample) -> Void)? = nil,
        scanID: UUID = UUID(),
        scopeRequest: (@Sendable () async -> ScopeRequest)? = nil,
        scopeUpdate: (@Sendable (ScopeSnapshot) async -> Void)? = nil,
        update: @Sendable (ScanProgress) async -> Void
    ) async -> ScanResult {
        await scan(
            plan: plan, diagnostics: diagnostics, scanID: scanID, scopeRequest: scopeRequest,
            scopeUpdate: scopeUpdate, injectedFailure: nil, update: update)
    }
    /// The app commits a replacement only after this worker has admitted a root.
    @concurrent package static func scan(
        plan: ScanPlan, scanID: UUID, rootAccepted: @Sendable @escaping () async -> Void,
        scopeRequest: @Sendable @escaping () async -> ScopeRequest,
        scopeUpdate: @Sendable @escaping (ScopeSnapshot) async -> Void,
        update: @Sendable (ScanProgress) async -> Void
    ) async -> ScanResult {
        await scan(
            plan: plan, scanID: scanID, scopeRequest: scopeRequest, scopeUpdate: scopeUpdate,
            rootAccepted: rootAccepted, injectedFailure: nil, update: update)
    }

    /// The scan in steps: discover and validate the roots, enumerate one directory at a time (classifying each entry
    /// as it is read), then finalize totals and coverage. `ScanRun` holds the worker's state between steps. `clock`
    /// paces publication; tests inject one to check the cadence exactly.
    @concurrent static func scan(
        plan: ScanPlan,
        diagnostics: (@Sendable (ScanMemorySample) -> Void)? = nil,
        scanID: UUID = UUID(),
        scopeRequest: (@Sendable () async -> ScopeRequest)? = nil,
        scopeUpdate: (@Sendable (ScopeSnapshot) async -> Void)? = nil,
        rootAccepted: (@Sendable () async -> Void)? = nil,
        injectedDiscovery: (@Sendable () -> DriveDiscovery)? = nil,
        injectedNodes: [ScanNode]? = nil,
        namespaceChildren: (@Sendable (Int) -> Void)? = nil,
        injectedVolumeFlags: (@Sendable (String) -> UInt32?)? = nil,
        injectedMountPoint: String? = nil,
        injectedFailure: (@Sendable (CoverageOperation, String) -> Int32?)?,
        clock: some Clock<Duration> = ContinuousClock(),
        update: @Sendable (ScanProgress) async -> Void
    ) async -> ScanResult {
        // A startup-disk scan's roots come from discovery, which logs its own count.
        if plan.startup {
            SpacewiseLog.scan.notice("scan started scope=startupDisk")
        } else {
            SpacewiseLog.scan.notice("scan started scope=folder roots=\(plan.roots.count, privacy: .public)")
        }
        var run = ScanRun(
            plan: plan, diagnostics: diagnostics, scanID: scanID, scopeRequest: scopeRequest,
            scopeUpdate: scopeUpdate, injectedDiscovery: injectedDiscovery,
            namespaceChildren: namespaceChildren, injectedVolumeFlags: injectedVolumeFlags,
            injectedMountPoint: injectedMountPoint,
            injectedFailure: injectedFailure, clock: clock)
        run.recordDiscoveryReasons()
        if let injectedNodes {
            run.adopt(injectedNodes)
        } else {
            run.validateRoots()
        }
        if run.hasAcceptedRoots, !Task.isCancelled { await rootAccepted?() }
        run.sample("initialized")
        await run.publish(update: update)
        await run.enumerate(update: update)
        return await run.finalize(update: update)
    }
    package static func finalizeCoverage(nodes: inout [ScanNode], coverage: LocationCoverage) {
        for id in nodes.indices {
            if let state = coverage.enumeration[id], state != .enumerated { nodes[id].allocationUnknown = true }
            if nodes[id].issue != nil { nodes[id].allocationUnknown = true }
        }
        for id in nodes.indices.reversed() {
            if let parent = nodes[id].parent {
                nodes[parent].logicalBytes += nodes[id].logicalBytes
                nodes[parent].allocatedBytes += nodes[id].allocatedBytes
                nodes[parent].allocationUnknown =
                    nodes[parent].allocationUnknown || nodes[id].allocationUnknown
                    || nodes[id].issue != nil
            }
        }
    }
    static func path(of id: Int, nodes: [ScanNode]) -> String {
        var names: [String] = []
        var cursor: Int? = id
        while let i = cursor {
            names.append(nodes[i].name)
            cursor = nodes[i].parent
        }
        return names.reversed().joined(separator: "/")
    }
}
