import Darwin
import Foundation
import SpacewiseFixtures
import Synchronization
import Testing

@testable import SpacewiseCore

@Test func linksAreCountedOnceAndAttributionIsDeterministic() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    let file = root.appending(path: "z-file")
    try Data(repeating: 1, count: 4096).write(to: file)
    try FileManager.default.linkItem(at: file, to: root.appending(path: "a-hard"))
    try FileManager.default.createSymbolicLink(at: root.appending(path: "symbolic"), withDestinationURL: root)
    let result = await Scanner.scan(plan: ScanPlan(folder: root)) { _ in }
    #expect(result.progress.entries == 3)
    #expect(result.progress.logicalBytes == 4096)
    #expect(result.progress.hardLinks == 1)
    #expect(result.progress.symbolicLinks == 1)
    let owner = try #require(result.nodes.first { $0.name == "a-hard" })
    #expect(owner.logicalBytes == 4096)
    let link = try #require(result.nodes.first { $0.name == "z-file" })
    #expect(link.hardLinkOwner == owner.id)
    #expect(result.nodes[0].logicalBytes == result.progress.logicalBytes)
    #expect(result.progress.state == .completed)
}

@Test func sparsePackageAndNavigation() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let package = fixture.root.appending(path: "Example.app")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
    let file = package.appending(path: "sparse")
    let fd = open(file.path, O_CREAT | O_WRONLY, 0o600)
    #expect(fd >= 0)
    defer { close(fd) }
    #expect(ftruncate(fd, 1 << 30) == 0)
    let result = await Scanner.scan(plan: ScanPlan(folder: fixture.root)) { _ in }
    #expect(result.progress.logicalBytes == 1 << 30)
    #expect(result.progress.allocatedBytes < result.progress.logicalBytes)
    let node = try #require(result.nodes.first { $0.kind == .package })
    #expect(result.children(of: node.id).count == 1)
    #expect(result.url(for: node.id)?.lastPathComponent == "Example.app")
    #expect(result.nodes[0].allocatedBytes == result.progress.allocatedBytes)
}

@Test func invalidAndSymlinkRootsAreRejected() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let link = fixture.root.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
    for root in [link, fixture.root.appending(path: "absent")] {
        let result = await Scanner.scan(plan: ScanPlan(folder: root)) { _ in }
        #expect(result.progress.state == .invalid)
        #expect(result.progress.issues[root == link ? .invalidRoot : .vanished] == 1)
        #expect(result.nodes.isEmpty)
    }
}

@Test func unreadableDirectoryIsCoverageNotZeroSuccess() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let denied = fixture.root.appending(path: "denied")
    try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false)
    #expect(chmod(denied.path, 0) == 0)
    let result = await Scanner.scan(plan: ScanPlan(folder: fixture.root)) { _ in }
    #expect(result.progress.state == .limited)
    #expect(result.progress.issues[.denied] == 1)
    #expect(result.nodes.first { $0.name == "denied" }?.issue == .denied)
}

@Test func cancellationIsCooperativeAndFinal() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    for i in 0..<1000 {
        #expect(FileManager.default.createFile(atPath: fixture.root.appending(path: "item-\(i)").path, contents: nil))
    }
    let worker = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await Scanner.scan(plan: ScanPlan(folder: fixture.root)) { _ in }
    }
    let result = await worker.value
    #expect(result.progress.state == .cancelled)
    #expect(result.progress.entries == 0)
    #expect(result.progress.finished)
}

@Test func cloudPolicyDoesNotRequireCloudMutation() {
    #expect(MetadataPolicy.isPlaceholder(flags: UInt32(SF_DATALESS)))
    #expect(MetadataPolicy.isPlaceholder(flags: 0) == false)
    #expect(MetadataPolicy.packageExtension("APP"))
}

@Test func diagnosticsPreserveResultsAndReportStorageWithoutPaths() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    #expect(
        FileManager.default.createFile(atPath: fixture.root.appending(path: "private-name").path, contents: Data([1])))
    let discovery = try fixture.startupDiscovery()
    let samples = Mutex<[ScanMemorySample]>([])
    let result = await Scanner.scan(
        plan: ScanPlan(folder: fixture.root),
        diagnostics: { sample in
            samples.withLock { $0.append(sample) }
        }, injectedDiscovery: { discovery }, injectedFailure: nil
    ) { _ in }
    #expect(result.progress.state == .completed)
    #expect(result.progress.entries == 1)
    let recorded = samples.withLock { $0 }
    #expect(recorded.first?.phase == "initialized")
    #expect(recorded.suffix(2).map(\.phase) == ["enumerated", "reduced"])
    let final = try #require(recorded.last)
    #expect(final.nodeCount == result.nodes.count)
    #expect(final.nodeCapacity >= final.nodeCount)
    #expect(try #require(final.residentBytes) > 0)
    #expect(try #require(final.peakRSSBytes) > 0)
    let json = try JSONEncoder().encode(recorded)
    let text = try #require(String(data: json, encoding: .utf8))
    #expect(text.contains(fixture.root.path) == false)
    #expect(text.contains("private-name") == false)
    #expect(try #require(result.nodes.first).logicalBytes == 1)
}

@Test func nodeCodingRetainsExistingFieldNamesAndValues() throws {
    let oldJSON =
        #"{"id":5,"parent":2,"name":"linked","kind":"file","logicalBytes":7,"allocatedBytes":8,"allocationUnknown":true,"hardLinkOwner":3,"issue":"placeholder","device":11,"inode":12}"#
        .data(using: .utf8)!
    let node = try JSONDecoder().decode(ScanNode.self, from: oldJSON)
    let encoded = try JSONEncoder().encode(node)
    #expect(
        try JSONSerialization.jsonObject(with: encoded) as? NSDictionary == JSONSerialization.jsonObject(with: oldJSON)
            as? NSDictionary)
    let initialized = ScanNode(
        id: 5, parent: 2, name: "linked", kind: .file, logicalBytes: 7,
        allocatedBytes: 8, allocationUnknown: true, hardLinkOwner: 3,
        issue: .placeholder, device: 11, inode: 12)
    #expect(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(initialized)) as? NSDictionary
            == JSONSerialization.jsonObject(with: oldJSON) as? NSDictionary)
}

// Mutations happen in the awaited initial callback, after root identity capture and
// before enumeration. These use real owned filesystem objects, not fake inode flags.
@Test(arguments: [false, true]) func replacedRootIsNeverTraversed(symlink: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root.appending(path: "root")
    let moved = fixture.root.appending(path: "original")
    let target = fixture.root.appending(path: "replacement")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    #expect(FileManager.default.createFile(atPath: target.appending(path: "sentinel").path, contents: nil))
    let result = await Scanner.scan(plan: ScanPlan(folder: root)) { progress in
        guard progress.state == .scanning, progress.entries == 0, progress.issues.isEmpty else { return }
        do {
            try FileManager.default.moveItem(at: root, to: moved)
            if symlink {
                try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
            } else {
                try FileManager.default.moveItem(at: target, to: root)
            }
        } catch { Issue.record("Disposable replacement failed") }
    }
    #expect(result.progress.state == .limited)
    #expect(result.progress.entries == 0)
    #expect(result.nodes.count == 1)
    #expect(result.nodes[0].issue == .interruptedVolume)
    #expect(result.nodes[0].allocationUnknown)
}

@Test func intermediateSymlinkRootResolvesToOwnedDirectory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let actual = fixture.root.appending(path: "actual")
    try FileManager.default.createDirectory(at: actual.appending(path: "child"), withIntermediateDirectories: true)
    let alias = fixture.root.appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
    let result = await Scanner.scan(plan: ScanPlan(folder: alias.appending(path: "child"))) { _ in }
    #expect(result.progress.state == .completed)
    #expect(result.roots == [actual.appending(path: "child").resolvingSymlinksInPath()])
}

@Test func realStartupVolumeMappingDistinguishesSameDeviceAliases() throws {
    let system = URL(fileURLWithPath: "/")
    let data = URL(fileURLWithPath: "/System/Volumes/Data")
    let systemID = try #require(Scanner.volumeIdentity(system))
    let dataID = try #require(Scanner.volumeIdentity(data))
    #expect(systemID != dataID)
    var systemStat = stat()
    var dataStat = stat()
    #expect(lstat(system.path, &systemStat) == 0)
    #expect(lstat(data.path, &dataStat) == 0)
    #expect(systemStat.st_dev == dataStat.st_dev)
    // These fixed directories are metadata-only observations; no user tree is enumerated.
    #expect(Scanner.volumeIdentity(URL(fileURLWithPath: "/Users")) == dataID)
    #expect(Scanner.volumeIdentity(URL(fileURLWithPath: "/System/Volumes/Data/Users")) == dataID)
    #expect(Scanner.volumeIdentity(URL(fileURLWithPath: "/System")) == systemID)
}

@Test(arguments: ["/Volumes", "/volumes", "/System/Volumes/Data/Volumes", "/System/Volumes"])
func realMountDirectoriesAreBoundariesNotTraversed(path: String) async {
    let plan = ScanPlan(folder: URL(fileURLWithPath: path))
    let result = await Scanner.scan(plan: plan) { _ in }
    #expect(result.nodes.isEmpty)
    #expect(result.progress.issues[.policyExcluded] == 1)
    #expect(result.coverage.records.first?.operation == .selectRoot)
}

@Test(arguments: [true, false])
func chosenFolderRequiresStartupTopologyEvidence(onStartupDrive: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root
    try Data([1]).write(to: root.appending(path: "owned"))
    let identity = try #require(Scanner.volumeIdentity(root))
    let evidence = DiscoveredRoot(
        url: URL(fileURLWithPath: StartupDrive.dataVolumePath),
        fsid: onStartupDrive ? identity : identity ^ 1,
        device: "disk3s5", uuid: UUID(), disk: "disk0")
    let result = await Scanner.scan(
        plan: ScanPlan(folder: root),
        injectedDiscovery: { DriveDiscovery(evidence: [evidence], roots: [evidence.url], unresolved: []) },
        injectedFailure: nil, update: { _ in })
    if onStartupDrive {
        #expect(result.roots == [root.resolvingSymlinksInPath()])
        #expect(result.progress.entries == 1)
    } else {
        #expect(result.roots.isEmpty)
        #expect(result.nodes.isEmpty)
        #expect(result.progress.entries == 0)
        #expect(result.coverage.records.first?.operation == .rootVolume)
        #expect(result.coverage.records.first?.policyDetail == "could not verify this volume is on the startup drive")
    }
}

@Test(arguments: [false, true])
func chosenMountedFolderEnumeratesWithinItsSelectedScope(selectSubfolder: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root.resolvingSymlinksInPath()
    let volumes = root.appending(path: "Volumes")
    let mount = volumes.appending(path: "Mounted")
    let selected = selectSubfolder ? mount.appending(path: "Selected") : mount
    let child = selected.appending(path: "child")
    let excluded = child.appending(path: "excluded")
    try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
    try Data([1]).write(to: child.appending(path: "seen"))
    try Data([1]).write(to: excluded.appending(path: "unseen"))
    let identity = try #require(Scanner.volumeIdentity(mount))
    let evidence = DiscoveredRoot(url: mount, fsid: identity, device: "disk3s5", uuid: UUID(), disk: "disk0")
    let policy = ScanPolicy(alsoExcluding: [excluded.path], mountedVolumesPath: volumes.path)
    let discovery: @Sendable () -> DriveDiscovery = {
        DriveDiscovery(evidence: [evidence], roots: [mount], unresolved: [])
    }

    let result = await Scanner.scan(
        plan: ScanPlan(folder: selected, policy: policy), injectedDiscovery: discovery,
        injectedMountPoint: mount.path, injectedFailure: nil, update: { _ in })
    #expect(result.roots.map(\.path) == [selected.path])
    #expect(result.coverage.enumeration[0] == .enumerated)
    #expect(Set(result.nodes.map(\.name)) == [selected.lastPathComponent, "child", "excluded", "seen"])
    let skipped = try #require(result.nodes.first { $0.name == "excluded" })
    #expect(result.coverage.enumeration[skipped.id] == .skipped)
    #expect(result.coverage.records.first?.policyDetail == "excluded by the caller")
    let seen = try #require(result.nodes.first { $0.name == "seen" })
    #expect(policy.eligibility(for: try #require(result.url(for: seen.id)).path) == .inspectionOnly)

    let ordinary = await Scanner.scan(
        plan: ScanPlan(folder: root, policy: policy), injectedDiscovery: discovery,
        injectedFailure: nil, update: { _ in })
    #expect(ordinary.nodes.map(\.name) == [root.lastPathComponent, "Volumes"])
    #expect(ordinary.coverage.records.first?.operation == .traverse)
    #expect(ordinary.coverage.records.first?.policyDetail == "mounted volume")
}

@Test(arguments: [
    (UInt32(MNT_LOCAL), true, true, "selected folder is outside a mount under /Volumes"),
    (UInt32(MNT_LOCAL), false, false, "could not verify this volume is on the startup drive"),
    (UInt32(MNT_LOCAL | MNT_REMOVABLE), false, true, "removable volume"),
    (UInt32(0), false, true, "network or non-local volume"),
])
func chosenMountedFolderRequiresSupportedMount(
    flags: UInt32, staleDirectory: Bool, matchingIdentity: Bool, reason: String
) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let volumes = fixture.root.resolvingSymlinksInPath().appending(path: "Volumes")
    let mount = volumes.appending(path: "Mounted")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let identity = try #require(Scanner.volumeIdentity(mount))
    let evidence = DiscoveredRoot(
        url: mount, fsid: matchingIdentity ? identity : identity ^ 1, device: "disk3s5", uuid: UUID(), disk: "disk0")
    let result = await Scanner.scan(
        plan: ScanPlan(folder: mount, policy: ScanPolicy(alsoExcluding: [], mountedVolumesPath: volumes.path)),
        injectedDiscovery: { DriveDiscovery(evidence: [evidence], roots: [mount], unresolved: []) },
        injectedVolumeFlags: { _ in flags }, injectedMountPoint: staleDirectory ? "/" : mount.path,
        injectedFailure: nil, update: { _ in })
    #expect(result.nodes.isEmpty)
    #expect(result.coverage.records.first?.operation == .rootVolume)
    #expect(result.coverage.records.first?.policyDetail == reason)
}

@Test func alternatePathsCannotBypassMountedFolderExclusion() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root.resolvingSymlinksInPath()
    let volumes = root.appending(path: "Volumes")
    let mount = volumes.appending(path: "Mounted")
    let child = mount.appending(path: "child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let incoming = root.appending(path: "incoming")
    let outgoing = volumes.appending(path: "outgoing")
    try FileManager.default.createSymbolicLink(at: incoming, withDestinationURL: mount)
    try FileManager.default.createSymbolicLink(at: outgoing, withDestinationURL: root)
    let policy = ScanPolicy(alsoExcluding: [], mountedVolumesPath: volumes.path)
    for alias in [
        incoming.appending(path: "child"), outgoing.appending(path: "incoming"),
        outgoing.appending(path: "Volumes/Mounted/child"),
    ] {
        let result = await Scanner.scan(plan: ScanPlan(folder: alias, policy: policy)) { _ in }
        #expect(result.nodes.isEmpty)
        #expect(result.coverage.records.first?.operation == .resolveRoot)
    }
}

@Test func mountedFolderResolutionIsRecheckedAfterTopologyVerification() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.root.resolvingSymlinksInPath()
    let volumes = root.appending(path: "Volumes")
    let mount = volumes.appending(path: "Mounted")
    let selected = mount.appending(path: "Selected")
    let moved = root.appending(path: "Moved")
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    let identity = try #require(Scanner.volumeIdentity(mount))
    let evidence = DiscoveredRoot(url: mount, fsid: identity, device: "disk3s5", uuid: UUID(), disk: "disk0")

    let result = await Scanner.scan(
        plan: ScanPlan(folder: selected, policy: ScanPolicy(alsoExcluding: [], mountedVolumesPath: volumes.path)),
        injectedDiscovery: {
            do {
                try FileManager.default.moveItem(at: mount, to: moved)
                try FileManager.default.createSymbolicLink(at: mount, withDestinationURL: moved)
            } catch {
                Issue.record("Could not replace fixture mount: \(error)")
            }
            return DriveDiscovery(evidence: [evidence], roots: [mount], unresolved: [])
        },
        injectedMountPoint: mount.path, injectedFailure: nil, update: { _ in })
    #expect(result.nodes.isEmpty)
    #expect(result.coverage.records.first?.operation == .identity)
    #expect(result.coverage.records.first?.reason == .interruptedVolume)
}

@Test(arguments: ["/Volumes/Chosen", "/volumes/Chosen", "/system/volumes/data/VOLUMES/Chosen"])
func mountedFolderAndContentsRemainInspectionOnly(path: String) {
    let mount = URL(fileURLWithPath: path, isDirectory: true)
    let homeFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Spacewise-policy-fixture")
    var tree = Tree()
    let mountedRoot = tree.root(mount.path)
    let personalRoot = tree.root(homeFolder.path)
    let mountedFile = tree.add(mountedRoot, "file", .file, bytes: 512)
    let personalFile = tree.add(personalRoot, "file", .file, bytes: 512)
    tree.nodes[mountedFile].blocksTrash = false
    tree.nodes[personalFile].blocksTrash = false
    var progress = ScanProgress()
    progress.state = .completed
    let result = ScanResult(
        id: UUID(), started: Date(), ended: Date(), roots: [mount, homeFolder], nodes: tree.nodes,
        progress: progress, volumes: [])
    let personalPath = homeFolder.appending(path: "file").path
    let mountedPath = mount.appending(path: "file").path
    #expect(result.url(for: mountedFile)?.path == mountedPath)
    #expect(result.trashTarget(for: personalFile)?.url.path == personalPath)
    #expect(result.trashTarget(for: mountedRoot) == nil)
    #expect(result.trashTarget(for: mountedFile) == nil)

    // Check mount policy directly since the home-directory guard also denies the mounted file.
    let policy = ScanPolicy()
    #expect(policy.classification(for: mountedPath) == .personal)
    #expect(policy.exclusion(for: mountedPath) == "mounted volume")
    #expect(policy.eligibility(for: mountedPath, kind: .file) == .inspectionOnly)
    #expect(policy.eligibility(for: personalPath, kind: .file) == .explicitSelectionAfterRevalidation)
}

@Test func ownedDataFirmlinkAliasesIdentifyOneObject() async throws {
    let fixture = try Fixture(base: URL(fileURLWithPath: "/private/var/tmp"))
    defer { fixture.remove() }
    let canonical = fixture.root
    let dataAlias = URL(fileURLWithPath: "/System/Volumes/Data" + canonical.path)
    var first = stat()
    var second = stat()
    #expect(lstat(canonical.path, &first) == 0)
    #expect(lstat(dataAlias.path, &second) == 0)
    #expect(first.st_ino == second.st_ino)
    #expect(Scanner.volumeIdentity(canonical) == Scanner.volumeIdentity(dataAlias))
    #expect(FileManager.default.createFile(atPath: canonical.appending(path: "owned").path, contents: nil))
    for root in [canonical, dataAlias] {
        let result = await Scanner.scan(plan: ScanPlan(folder: root)) { _ in }
        #expect(result.progress.entries == 1)
        #expect(result.progress.state == .completed)
    }
}

@Test func precisePolicyAndBoundedCoverage() {
    let policy = ScanPolicy()
    for path in [
        "/Users/person/dev", "/Users/person/cache", "/Users/person/project/node_modules", "/Users/person/.cargo",
    ] {
        #expect(policy.exclusion(for: path) == nil)
        #expect(policy.eligibility(for: path) == .explicitSelectionAfterRevalidation)
    }
    #expect(policy.exclusion(for: "/dev/fd") != nil)
    #expect(policy.exclusion(for: "/developer") == nil)
    #expect(policy.classification(for: "/System/Volumes/Data/Library/Developer") == .developerManaged)
    #expect(policy.eligibility(for: "/Users/person/Library/Application Support") == .inspectionOnly)
    var coverage = LocationCoverage(limit: 1)
    coverage.record(path: "/a", nodeID: nil, operation: .fstatat, reason: .denied)
    coverage.record(path: "/a", nodeID: nil, operation: .open, reason: .denied)
    #expect(coverage.events == 2)
    #expect(coverage.exactUniqueLocations == nil)  // second distinct reason exceeds the one-record bound
    coverage.record(path: "/b", nodeID: nil, operation: .fstatat, reason: .metadata)
    #expect(coverage.truncated)
    #expect(coverage.exactUniqueLocations == nil)
    #expect(coverage.records.count == 1)
}

@Test func managedPolicyUsesAnchoredComponentsAndKinds() {
    let policy = ScanPolicy()
    #expect(policy.classification(for: "/Users/person/projects/Library/source") == .personal)
    #expect(policy.classification(for: "/Users/person/Library/Developer") == .developerManaged)
    #expect(policy.classification(for: "/Applications/Example.app") == .applicationManaged)
    #expect(policy.eligibility(for: "/Users/person/folder", kind: .directory) == .inspectionOnly)
    #expect(policy.eligibility(for: "/Users/person/bundle.app", kind: .package) == .inspectionOnly)
    #expect(policy.eligibility(for: "/Users/person/link", kind: .symbolicLink) == .inspectionOnly)
    #expect(policy.eligibility(for: "/Users/person/socket", kind: .other) == .inspectionOnly)
}

@Test func homeLibraryClassificationFollowsTheInjectedHome() {
    let policy = ScanPolicy(alsoExcluding: [], homePath: "/System/Volumes/Data/Relocated/person")
    for home in ["/Relocated/person", "/System/Volumes/Data/Relocated/person", "/Users/another"] {
        let library = home + "/Library"
        #expect(policy.classification(for: library) == .applicationManaged)
        #expect(policy.classification(for: library + "/Developer/Tools") == .developerManaged)
        #expect(policy.classification(for: library + "/DeveloperTools") == .applicationManaged)
        #expect(policy.eligibility(for: library + "/file", kind: .file) == .inspectionOnly)
        #expect(policy.exclusion(for: library) == nil)
    }
    for path in [
        "/Relocated/person/project/Library", "/Relocated/person-other/Library", "/Relocated/person/LibraryCopies",
    ] {
        #expect(policy.classification(for: path) == .personal)
        #expect(policy.eligibility(for: path + "/file", kind: .file) == .explicitSelectionAfterRevalidation)
        #expect(policy.exclusion(for: path) == nil)
    }
}
