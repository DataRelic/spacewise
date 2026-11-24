import Darwin
import Foundation

/// The state of one scan, owned by its worker and advanced one step at a time by `Scanner.scan`.
///
/// Descriptor-based traversal: every directory is re-validated by lstat, then opened with O_NOFOLLOW and checked
/// again through its descriptor (inode, device and filesystem identity) before it is listed. Entries are read with
/// fstatat relative to that descriptor. Hard links are counted once; unknown sizes stay separate from zero.
///
/// `clock` paces publication: progress at most every 200 ms, the live map at most once a second per request.
struct ScanRun<ScanClock: Clock> where ScanClock.Duration == Duration {
    private typealias Identity = Scanner.Identity

    let plan: ScanPlan
    let scanID: UUID
    private let diagnostics: (@Sendable (ScanMemorySample) -> Void)?
    private let scopeRequest: (@Sendable () async -> ScopeRequest)?
    private let scopeUpdate: (@Sendable (ScopeSnapshot) async -> Void)?
    private let injectedVolumeFlags: (@Sendable (String) -> UInt32?)?
    private let injectedFailure: (@Sendable (CoverageOperation, String) -> Int32?)?
    private let injectedMountPoint: String?

    private let began: Date
    private let clock: ScanClock
    private let start: ScanClock.Instant
    private var last: ScanClock.Instant
    private(set) var progress = ScanProgress()
    private var nodes: [ScanNode] = []
    private var owners: [Identity: Int] = [:]
    private var rootDevices = Set<UInt64>()
    private var selectedMountedRoots: [UInt64: String] = [:]
    private var pending: [(URL, Int, UInt64)] = []
    private var actualRoots: [URL] = []
    private var capacityRoots: [URL] = []
    private let discovery: DriveDiscovery
    private let injectedDiscovery: (@Sendable () -> DriveDiscovery)?
    private let selectedRoots: [URL]
    private let startupIdentities: Set<UInt64>
    private var coverage: LocationCoverage
    private var navigation = ProgressiveIndex()
    private var revision: UInt64 = 0
    private var lastTreemap: (parent: Int?, generation: UInt64, at: ScanClock.Instant)?
    /// True when the nodes came from `adopt` rather than the filesystem.
    private var adoptedNodes = false

    init(
        plan: ScanPlan, diagnostics: (@Sendable (ScanMemorySample) -> Void)?, scanID: UUID,
        scopeRequest: (@Sendable () async -> ScopeRequest)?, scopeUpdate: (@Sendable (ScopeSnapshot) async -> Void)?,
        injectedDiscovery: (@Sendable () -> DriveDiscovery)?, namespaceChildren: (@Sendable (Int) -> Void)?,
        injectedVolumeFlags: (@Sendable (String) -> UInt32?)?,
        injectedMountPoint: String?,
        injectedFailure: (@Sendable (CoverageOperation, String) -> Int32?)?, clock: ScanClock
    ) {
        self.plan = plan
        self.diagnostics = diagnostics
        self.scanID = scanID
        self.scopeRequest = scopeRequest
        self.scopeUpdate = scopeUpdate
        self.injectedVolumeFlags = injectedVolumeFlags
        self.injectedMountPoint = injectedMountPoint
        self.injectedFailure = injectedFailure
        began = Date()
        self.clock = clock
        start = clock.now
        last = start
        self.injectedDiscovery = injectedDiscovery
        discovery = plan.startup ? (injectedDiscovery?() ?? DriveDiscovery.discover()) : DriveDiscovery(unresolved: [])
        selectedRoots = plan.startup ? discovery.roots : plan.roots
        startupIdentities = Set(discovery.evidence.map(\.fsid))
        coverage = LocationCoverage(wholeDrive: plan.startup)
        navigation.namespaceChildren = namespaceChildren
    }

    var hasAcceptedRoots: Bool { !actualRoots.isEmpty && !progress.cancelled }

    // MARK: Validate roots

    /// Volumes discovery could not verify or found unmounted, each recorded at its own location so Scan details can
    /// tell them apart. A cancelled discovery is cancellation, not an issue.
    mutating func recordDiscoveryReasons() {
        for reason in discovery.reasons {
            let issue: CoverageIssue
            let detail: String
            let location: String
            switch reason {
            case .unmounted(let device):
                issue = .unmounted
                detail = device
                location = "/dev/" + device
            case .unresolved(let value, let volume):
                issue = .unresolvedVolume
                detail = value
                location = volume ?? "/"
            case .cancelled:
                progress.state = .cancelled
                continue
            }
            progress.issues[issue, default: 0] += 1
            coverage.record(path: location, nodeID: nil, operation: .rootVolume, reason: issue, policyDetail: detail)
        }
    }

    mutating func validateRoots() {
        for root in selectedRoots {
            if Task.isCancelled || progress.cancelled {
                progress.state = .cancelled
                break
            }
            validateRoot(root)
            if progress.state == .cancelled { break }
        }
    }

    /// Admits one selected root as a scan root node, or records why it cannot be scanned.
    private mutating func validateRoot(_ root: URL) {
        let mountedSelection = !plan.startup && plan.policy.isMountedVolumeDescendant(root.path)
        let mountedCandidate = mountedSelection ? root.path : nil
        if !plan.startup, let reason = plan.policy.exclusion(for: root.path, withinSelectedMount: mountedCandidate) {
            issue(.policyExcluded)
            coverage.record(
                path: root.path, nodeID: nil, operation: .selectRoot, reason: .policyExcluded,
                policyDetail: reason)
            return
        }
        var info = stat()
        let resolved = plan.startup ? root : root.resolvingSymlinksInPath()
        let escapedMount = mountedSelection && !plan.policy.isSameMountedPath(resolved.path, as: root.path)
        if !plan.startup,
            let reason = escapedMount
                ? "selected folder resolves outside its mounted path"
                : plan.policy.exclusion(for: resolved.path, withinSelectedMount: mountedSelection ? resolved.path : nil)
        {
            issue(.policyExcluded)
            coverage.record(
                path: root.path, nodeID: nil, operation: .resolveRoot, reason: .policyExcluded,
                policyDetail: reason)
            return
        }
        guard root.isFileURL else {
            record(.invalidRoot, root.path, nil, .rootMetadata)
            return
        }
        guard lstat(root.path, &info) == 0 else {
            let code = errno
            record(Scanner.failure(code), root.path, nil, .rootMetadata, errnoCode: code)
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            issue(.invalidRoot)
            coverage.record(path: root.path, nodeID: nil, operation: .rootMetadata, reason: .invalidRoot)
            return
        }
        if MetadataPolicy.isPlaceholder(flags: info.st_flags) {
            record(.placeholder, root.path, nil, .placeholder)
            return
        }
        var rootFS = statfs()
        guard statfs(root.path, &rootFS) == 0 else {
            let code = errno
            record(Scanner.failure(code), root.path, nil, .rootVolume, errnoCode: code)
            return
        }
        let device = Scanner.volumeIdentity(rootFS)
        if plan.startup {
            guard let expected = discovery.evidence.first(where: { $0.url == root }),
                let observed = DriveDiscovery.mountedIdentity(root.path),
                observed.0 == expected.fsid, observed.1 == "/dev/" + expected.device
            else {
                record(.interruptedVolume, root.path, nil, .identity)
                return
            }
        }
        let volumeFlags = injectedVolumeFlags?(root.path) ?? rootFS.f_flags
        let volume = SelectedVolumeMetadata(
            identity: device, local: volumeFlags & UInt32(MNT_LOCAL) != 0,
            removable: volumeFlags & UInt32(MNT_REMOVABLE) != 0)
        var verifiedIdentities = startupIdentities
        if !plan.startup, volume.local, !volume.removable {
            let mount = injectedMountPoint ?? DriveDiscovery.mountPoint(&rootFS)
            if mountedSelection,
                !plan.policy.isMountedVolumeDescendant(mount)
                    || !plan.policy.isWithinMountedPath(resolved.path, root: mount)
            {
                issue(.policyExcluded)
                coverage.record(
                    path: root.path, nodeID: nil, operation: .rootVolume, reason: .policyExcluded,
                    policyDetail: "selected folder is outside a mount under /Volumes")
                return
            }
            let topology = injectedDiscovery?() ?? DriveDiscovery.discover(selectedMount: mount)
            guard !Task.isCancelled, !topology.reasons.contains(where: \.isCancelled) else {
                progress.state = .cancelled
                return
            }
            verifiedIdentities = Set(
                topology.evidence.filter { !mountedSelection || $0.url.path == mount }.map(\.fsid))
        }
        if let rejection = volume.rejection(in: verifiedIdentities) {
            issue(.policyExcluded)
            coverage.record(
                path: root.path, nodeID: nil, operation: .rootVolume, reason: .policyExcluded,
                policyDetail: rejection)
            return
        }
        let scanRoot = root.resolvingSymlinksInPath()
        guard plan.startup || scanRoot.path == resolved.path else {
            record(.interruptedVolume, root.path, nil, .identity)
            return
        }
        guard rootDevices.insert(device).inserted else {
            record(.volumeBoundary, root.path, nil, .rootVolume)
            return
        }
        let id = nodes.count
        nodes.append(
            ScanNode(
                id: id, parent: nil, name: plan.startup ? root.path : root.lastPathComponent,
                kind: .directory, device: device, inode: UInt64(info.st_ino)))
        navigation.append(nodes[id])
        coverage.enumeration[id] = .unopened
        if mountedSelection { selectedMountedRoots[device] = scanRoot.path }
        actualRoots.append(scanRoot)
        pending.append((scanRoot, id, device))
    }

    /// Tests only: start from a prepared node array instead of the filesystem.
    mutating func adopt(_ injectedNodes: [ScanNode]) {
        adoptedNodes = true
        nodes = injectedNodes
        actualRoots = selectedRoots
        for node in nodes {
            navigation.append(node)
            if node.kind == .file {
                progress.entries += 1
                progress.logicalBytes += node.logicalBytes
                progress.allocatedBytes += node.allocatedBytes
                navigation.attribute(
                    logical: node.logicalBytes, allocated: node.allocatedBytes, to: node.parent,
                    nodes: nodes)
            } else {
                coverage.enumeration[node.id] = .partial
            }
        }
    }

    // MARK: Enumerate

    /// Pending directories, one open at a time, until none remain or the scan is cancelled.
    mutating func enumerate(update: @Sendable (ScanProgress) async -> Void) async {
        guard !progress.cancelled else { return }
        while let (directory, parent, device) = pending.popLast() {
            if Task.isCancelled {
                progress.state = .cancelled
                coverage.enumeration[parent] = .cancelled
                break
            }
            guard let opened = openForListing(directory, parent: parent, device: device) else {
                if progressIsDue { await publishProgress(update: update) }
                continue
            }
            await list(opened, update: update)
            closedir(opened.stream)
            if Task.isCancelled {
                progress.state = .cancelled
                if coverage.enumeration[parent] == .partial { coverage.enumeration[parent] = .cancelled }
                break
            }
        }
    }

    private struct OpenDirectory {
        let url: URL
        let node: Int
        let device: UInt64
        let fd: Int32
        let stream: UnsafeMutablePointer<DIR>
        /// lstat of the directory, confirmed against its descriptor.
        let status: stat
    }

    /// Ends a pending folder whose identity check could not be made at all: it is never listed and never retried.
    private mutating func failIdentityCheck(_ directory: URL, parent: Int, errnoCode code: Int32) {
        let problem = Scanner.failure(code)
        nodes[parent].issue = problem
        coverage.enumeration[parent] = .openFailed
        navigation.entryChanged(parent)
        record(problem, directory.path, parent, .identity, errnoCode: code)
    }

    /// Re-validates and opens one pending directory. nil when it was skipped; the reason is already recorded.
    private mutating func openForListing(_ directory: URL, parent: Int, device: UInt64) -> OpenDirectory? {
        var current = stat()
        guard lstat(directory.path, &current) == 0 else {
            // The folder could not be looked at, which says nothing about whether it was replaced: classify the
            // failure itself (a folder removed since discovery is vanished, ENOENT).
            failIdentityCheck(directory, parent: parent, errnoCode: errno)
            return nil
        }
        let observedVolume = Scanner.lookUpVolumeIdentity(directory)
        if case .failure(let failure) = observedVolume {
            // Likewise, a failed statfs is not evidence of another volume.
            failIdentityCheck(directory, parent: parent, errnoCode: failure.errnoCode)
            return nil
        }
        guard case .success(let volume) = observedVolume, volume == device,
            UInt64(current.st_ino) == nodes[parent].inode
        else {
            nodes[parent].issue = .interruptedVolume
            // No longer the folder that was discovered: it is never listed and never retried.
            coverage.enumeration[parent] = .openFailed
            navigation.entryChanged(parent)
            record(.interruptedVolume, directory.path, parent, .identity)
            return nil
        }
        // Reject newly dataless directories before opening, including selected roots.
        if MetadataPolicy.isPlaceholder(flags: current.st_flags) {
            nodes[parent].issue = .placeholder
            nodes[parent].allocationUnknown = true
            coverage.enumeration[parent] = .skipped
            navigation.entryChanged(parent)
            record(.placeholder, directory.path, parent, .placeholder)
            return nil
        }
        // O_NOFOLLOW rejects a directory swapped for a symlink after lstat.
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            let problem = Scanner.failure(code)
            nodes[parent].issue = problem
            coverage.enumeration[parent] = .openFailed
            navigation.entryChanged(parent)
            record(problem, directory.path, parent, .open, errnoCode: code)
            return nil
        }
        var opened = stat()
        var openedVolume = statfs()
        guard fstat(fd, &opened) == 0, opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
            fstatfs(fd, &openedVolume) == 0, Scanner.volumeIdentity(openedVolume) == device
        else {
            close(fd)
            nodes[parent].issue = .interruptedVolume
            coverage.enumeration[parent] = .openFailed
            navigation.entryChanged(parent)
            record(.interruptedVolume, directory.path, parent, .identity)
            return nil
        }
        if nodes[parent].parent == nil { capacityRoots.append(directory) }
        let injectedOpen = injectedFailure?(.fdopendir, directory.path)
        let streamValue = injectedOpen == nil ? fdopendir(fd) : nil
        guard let stream = streamValue else {
            let code = injectedOpen ?? errno
            close(fd)
            nodes[parent].issue = .enumeration
            coverage.enumeration[parent] = .openFailed
            navigation.entryChanged(parent)
            record(.enumeration, directory.path, parent, .fdopendir, errnoCode: code)
            return nil
        }
        coverage.enumeration[parent] = .partial
        return OpenDirectory(url: directory, node: parent, device: device, fd: fd, stream: stream, status: current)
    }

    /// Reads every entry of an open directory, classifying each, and publishes progress on the scan's cadence.
    private mutating func list(_ directory: OpenDirectory, update: @Sendable (ScanProgress) async -> Void) async {
        let parent = directory.node
        while !Task.isCancelled {
            errno = 0
            let injectedRead = injectedFailure?(.readdir, directory.url.path)
            let nextEntry = injectedRead == nil ? readdir(directory.stream) : nil
            if let injectedRead { errno = injectedRead }
            guard let entry = nextEntry else {
                let code = errno
                if code != 0 {
                    record(.enumeration, directory.url.path, parent, .readdir, errnoCode: code)
                    nodes[parent].issue = .enumeration
                    coverage.enumeration[parent] = .listingFailed
                    navigation.entryChanged(parent)
                    if progressIsDue { await publishProgress(update: update) }
                } else {
                    coverage.enumeration[parent] = .enumerated
                    navigation.finishedListing(parent, nodes: nodes, coverage: coverage)
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            classify(name, in: directory)
            if progressIsDue { await publishProgress(update: update) }
        }
    }

    // MARK: Classify

    /// Reads one entry's metadata and admits it as a node: decides whether a directory is followed, excluded or
    /// left at a volume boundary, and attributes a file's bytes, once per hard-linked inode. Records unreadable
    /// metadata against the parent.
    private mutating func classify(_ name: String, in directory: OpenDirectory) {
        let parent = directory.node
        let device = directory.device
        var info = stat()
        let injectedStat = injectedFailure?(.fstatat, directory.url.path + "/" + name)
        let statResult = injectedStat == nil ? fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) : -1
        if let injectedStat { errno = injectedStat }
        guard statResult == 0 else {
            let code = errno
            let problem = Scanner.failure(code)
            issue(problem)
            nodes[parent].allocationUnknown = true
            coverage.record(
                path: directory.url.path + "/" + name, nodeID: nil, operation: .fstatat, reason: problem,
                parentID: parent, errnoCode: code)
            return
        }
        // Regular files need only descriptor-relative metadata; directories need URLs
        // for package detection, volume validation and later traversal.
        let directoryURL = info.st_mode & S_IFMT == S_IFDIR ? directory.url.appendingPathComponent(name) : nil
        let kind = MetadataPolicy.kind(mode: info.st_mode, extension: directoryURL?.pathExtension ?? "")
        let id = nodes.count
        var node = ScanNode(id: id, parent: parent, name: name, kind: kind, device: device, inode: UInt64(info.st_ino))
        node.blocksTrash = kind != .file || TrashTarget.protectedMetadata(info)
        progress.entries += 1
        var metadataErrno: Int32?
        if directoryURL != nil { coverage.enumeration[id] = .unopened }
        if let directoryURL,
            let reason = plan.policy.exclusion(
                for: directoryURL.path, withinSelectedMount: selectedMountedRoots[device],
                insideAdmittedVolume: isInsideSelectedAuxiliaryRoot(directoryURL))
        {
            node.issue = .policyExcluded
            coverage.enumeration[id] = .skipped
            issue(.policyExcluded)
            coverage.record(
                path: directoryURL.path, nodeID: id, operation: .traverse, reason: .policyExcluded,
                policyDetail: reason)
        } else if let crossing = volumeCrossing(info, kind: kind, url: directoryURL, in: directory, name: name) {
            switch crossing {
            case .boundary:
                node.issue = .volumeBoundary
                if directoryURL != nil { coverage.enumeration[id] = .skipped }
                issue(.volumeBoundary)
            case .unidentifiable(let code):
                // The volume could not be identified, so the folder is unreadable rather than excluded: it is never
                // listed, and the failure is recorded with its errno below.
                let problem = Scanner.failure(code)
                node.issue = problem
                node.allocationUnknown = true
                issue(problem)
                coverage.enumeration[id] = .openFailed
                metadataErrno = code
            }
        } else if MetadataPolicy.isPlaceholder(flags: info.st_flags) && kind != .file {
            node.issue = .placeholder
            node.allocationUnknown = true
            if directoryURL != nil { coverage.enumeration[id] = .skipped }
            issue(.placeholder)
        } else if kind == .symbolicLink {
            progress.symbolicLinks += 1
        } else if kind == .directory || kind == .package {
            pending.append((directoryURL!, id, device))
        } else if kind == .file {
            attributeFile(&node, info: info, name: name, parent: parent, device: device)
        }
        if let problem = node.issue, problem != .policyExcluded {
            coverage.record(
                path: directory.url.path + "/" + name, nodeID: id, operation: .metadata, reason: problem,
                errnoCode: metadataErrno)
        }
        nodes.append(node)
        navigation.append(node)
        if scopeUpdate != nil {
            navigation.attribute(
                logical: node.logicalBytes, allocated: node.allocatedBytes, to: node.parent,
                nodes: nodes)
        }
    }

    /// System/Volumes includes Data and mounted volumes: never recurse from the system root. A path the other-volume
    /// rules would exclude is still followed when it lies inside an auxiliary volume the whole-drive plan selected as
    /// its own root.
    private func isInsideSelectedAuxiliaryRoot(_ url: URL) -> Bool {
        plan.startup
            && selectedRoots.contains(where: {
                $0.path != "/" && $0.path != StartupDrive.dataVolumePath
                    && (url.path == $0.path || url.path.hasPrefix($0.path + "/"))
            })
    }

    private enum VolumeCrossing {
        /// Another device or filesystem than the parent.
        case boundary
        /// `statfs` failed, so which volume the folder is on is unknown.
        case unidentifiable(errnoCode: Int32)
    }

    /// How the entry leaves its parent's volume, or nil when it stays on it. A boundary is an entry on another device
    /// or filesystem than its parent, or the system root's /System/Volumes, which holds Data and mounted volumes.
    /// Dataless folders are not probed with statfs. The checks run in this order and stop at the first that decides.
    private func volumeCrossing(
        _ info: stat, kind: NodeKind, url: URL?, in directory: OpenDirectory,
        name: String
    ) -> VolumeCrossing? {
        if info.st_dev != directory.status.st_dev { return .boundary }
        if (kind == .directory || kind == .package) && !MetadataPolicy.isPlaceholder(flags: info.st_flags) {
            switch Scanner.lookUpVolumeIdentity(url!) {
            case .success(let volume) where volume != directory.device: return .boundary
            case .success: break
            case .failure(let failure): return .unidentifiable(errnoCode: failure.errnoCode)
            }
        }
        if plan.startup && directory.url.path == "/System" && name == "Volumes" { return .boundary }
        return nil
    }

    /// Logical size, allocation (unknown for placeholders) and hard-link ownership for a regular file.
    private mutating func attributeFile(_ node: inout ScanNode, info: stat, name: String, parent: Int, device: UInt64) {
        let identity = Identity(device: device, inode: UInt64(info.st_ino))
        node.logicalBytes = UInt64(max(0, info.st_size))
        if MetadataPolicy.isPlaceholder(flags: info.st_flags) {
            node.issue = .placeholder
            node.allocationUnknown = true
            issue(.placeholder)
        } else {
            node.allocatedBytes = UInt64(max(0, info.st_blocks)) * 512
        }
        if info.st_nlink > 1, let owner = owners[identity] {
            // Attribution is deterministic: lowest raw relative path in this scan's traversal scope.
            // Owner swaps preserve discoverability and ensure scope totals count the inode once.
            let oldPath = Scanner.path(of: owner, nodes: nodes)
            let newPath = Scanner.path(of: parent, nodes: nodes) + "/" + name
            if newPath.utf8.lexicographicallyPrecedes(oldPath.utf8) {
                if scopeUpdate != nil {
                    navigation.attribute(
                        logical: nodes[owner].logicalBytes, allocated: nodes[owner].allocatedBytes,
                        to: nodes[owner].parent, nodes: nodes, subtract: true)
                }
                // The owner is a regular file (never a firm-link stub), so zeroing it cannot change namespace
                // topology; its managed-group bytes were already removed by the signed subtraction above.
                nodes[owner].hardLinkOwner = node.id
                nodes[owner].logicalBytes = 0
                nodes[owner].allocatedBytes = 0
                owners[identity] = node.id
                // Resolve owner chains once after enumeration; avoid quadratic work for many links.
            } else {
                node.hardLinkOwner = owner
                node.logicalBytes = 0
                node.allocatedBytes = 0
            }
            progress.hardLinks += 1
        } else {
            if info.st_nlink > 1 { owners[identity] = node.id }
            progress.logicalBytes += node.logicalBytes
            progress.allocatedBytes += node.allocatedBytes
        }
    }

    // MARK: Finalize

    /// Settles the result: cancelled bookkeeping, hard-link owners, totals and coverage, the final state and the last
    /// publication.
    mutating func finalize(update: @Sendable (ScanProgress) async -> Void) async -> ScanResult {
        // Sample the requested scope before committing, since reading it can suspend the worker.
        let terminalRequest: ScopeRequest? =
            if let scopeRequest, scopeUpdate != nil {
                await scopeRequest()
            } else {
                nil
            }
        sample("enumerated")
        if Task.isCancelled { progress.state = .cancelled }
        if adoptedNodes {
            for id in coverage.enumeration.keys where coverage.enumeration[id] == .partial {
                coverage.enumeration[id] = progress.cancelled ? .cancelled : .enumerated
            }
        }
        pending.removeAll()
        // Parents precede children; reduce once rather than updating every ancestor for each entry.
        for id in nodes.indices where nodes[id].hardLinkOwner != nil {
            nodes[id].hardLinkOwner = owners[Identity(device: nodes[id].device, inode: nodes[id].inode)]
        }
        Scanner.finalizeCoverage(nodes: &nodes, coverage: coverage)
        sample("reduced")
        if progress.state != .cancelled {
            progress.state = nodes.isEmpty ? .invalid : (progress.issues.isEmpty ? .completed : .limited)
        }
        // Coverage must be known at construction: the category totals and the unified-drive namespace read
        // `wholeDrive`.
        // Roots are opened last first, so on a startup-disk scan the first one opened is an auxiliary volume. The
        // capacity wanted is the startup volume's.
        let startupVolumeRoot =
            capacityRoots.first { $0.path == "/" }
            ?? capacityRoots.first { $0.path == StartupDrive.dataVolumePath }
            ?? capacityRoots.first
        let volumeRoots: [URL]
        if Task.isCancelled || progress.cancelled {
            volumeRoots = []
        } else if plan.startup {
            volumeRoots = startupVolumeRoot.map { [$0] } ?? []
        } else {
            volumeRoots = capacityRoots
        }
        let volumes = volumeRoots.map {
            VolumeContext(
                root: $0,
                scope: plan.startup
                    ? "Startup APFS volume; capacities may share a container"
                    : "Selected folder's volume")
        }
        let indexing = diagnostics.map { diagnostics in
            let count = nodes.count
            let capacity = nodes.capacity
            let hardLinks = owners.count
            return {
                diagnostics(
                    .capture(
                        phase: "indexing", nodeCount: count, nodeCapacity: capacity,
                        pendingDirectories: 0, hardLinkIdentities: hardLinks))
            }
        }
        var finalNavigation = ProgressiveIndex()
        swap(&finalNavigation, &navigation)
        var result = ScanResult(
            id: scanID, started: began, ended: Date(), roots: actualRoots, nodes: nodes,
            progress: progress, coverage: coverage, volumes: volumes, navigation: consume finalNavigation,
            indexing: indexing)
        result.finish(elapsedSeconds: start.duration(to: clock.now).totalSeconds)
        progress = result.progress
        logOutcome()
        if let terminalRequest, let scopeUpdate {
            revision += 1
            await scopeUpdate(result.terminalSnapshot(request: terminalRequest, revision: revision))
        }
        await update(progress)
        return result
    }

    /// Finish, cancel or failure, with counts and a duration only.
    private func logOutcome() {
        let elapsedMs = Int((progress.elapsedSeconds * 1000).rounded())
        let issues = SpacewiseLog.issueCounts(progress.issues)
        let errnos = SpacewiseLog.errnoCounts(coverage.records)
        switch progress.state {
        case .cancelled:
            SpacewiseLog.scan.notice(
                """
                scan cancelled entries=\(progress.entries, privacy: .public) nodes=\(nodes.count, privacy: .public) \
                issues=\(issues, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)
                """)
        case .invalid:
            SpacewiseLog.scan.error(
                """
                scan failed state=invalid roots=\(actualRoots.count, privacy: .public) \
                issues=\(issues, privacy: .public) errno=\(errnos, privacy: .public) \
                elapsedMs=\(elapsedMs, privacy: .public)
                """)
        case .completed, .limited, .scanning:
            SpacewiseLog.scan.notice(
                """
                scan finished state=\(progress.state.rawValue, privacy: .public) \
                entries=\(progress.entries, privacy: .public) nodes=\(nodes.count, privacy: .public) \
                hardLinks=\(progress.hardLinks, privacy: .public) symlinks=\(progress.symbolicLinks, privacy: .public) \
                issues=\(issues, privacy: .public) events=\(coverage.events, privacy: .public) \
                truncated=\(coverage.truncated, privacy: .public) errno=\(errnos, privacy: .public) \
                elapsedMs=\(elapsedMs, privacy: .public)
                """)
        }
    }

    // MARK: Publication and records

    private var progressIsDue: Bool { last.duration(to: clock.now) >= .milliseconds(200) }

    private mutating func publishProgress(update: @Sendable (ScanProgress) async -> Void) async {
        sample("enumerating")
        progress.elapsedSeconds = start.duration(to: clock.now).totalSeconds
        await publish(update: update)
        last = clock.now
    }

    /// The scope snapshot (when one is requested), then aggregate progress. The callback is awaited, which bounds
    /// how far the worker runs ahead of its consumer.
    mutating func publish(update: @Sendable (ScanProgress) async -> Void) async {
        guard !progress.cancelled, !Task.isCancelled else { return }
        await publishScope()
        guard !Task.isCancelled else { return }
        await update(progress)
    }

    private mutating func publishScope() async {
        guard let scopeRequest, let scopeUpdate else { return }
        let request = await scopeRequest()
        revision += 1
        // The map is heavier than a page: attach it at most about once a second per request, never on the final
        // publish.
        var includeTreemap = false
        if request.wantsTreemap, progress.state == .scanning {
            let now = clock.now
            if let last = lastTreemap, last.parent == request.parent, last.generation == request.generation,
                last.at.duration(to: now) < .seconds(1)
            {
                includeTreemap = false
            } else {
                includeTreemap = true
                lastTreemap = (request.parent, request.generation, now)
            }
        }
        let snapshot = navigation.snapshot(
            scanID: scanID, revision: revision, request: request, nodes: nodes,
            urls: actualRoots, coverage: coverage, progress: progress,
            includeTreemap: includeTreemap)
        guard !Task.isCancelled || progress.state == .cancelled else { return }
        await scopeUpdate(snapshot)
    }

    private mutating func issue(_ value: CoverageIssue) { progress.issues[value, default: 0] += 1 }

    private mutating func record(
        _ value: CoverageIssue, _ path: String, _ node: Int?, _ operation: CoverageOperation,
        parent: Int? = nil, errnoCode: Int32? = nil
    ) {
        issue(value)
        coverage.record(
            path: path, nodeID: node, operation: operation, reason: value, parentID: parent,
            errnoCode: errnoCode)
    }

    func sample(_ phase: String) {
        guard let diagnostics else { return }
        diagnostics(
            .capture(
                phase: phase, nodeCount: nodes.count, nodeCapacity: nodes.capacity,
                pendingDirectories: pending.count, hardLinkIdentities: owners.count))
    }
}
