import Foundation
import SpacewiseCore

/// Made-up scan results for the tests. Nothing here reads the filesystem, and the app does not link this module.

public enum PresentationFixtures {}

public enum PresentationScenario: CaseIterable, Sendable { case complete, scanning, limited, cancelled, empty, stale }
public struct PresentationFixture: Sendable {
    public let result: ScanResult
    public let snapshot: ScopeSnapshot
    public let freshness: ResultFreshness
}
extension PresentationFixtures {
    /// Distinct synthetic outcomes, with no filesystem reads. Freshness is independent of outcome.
    public static func scenario(_ scenario: PresentationScenario) -> PresentationFixture {
        var nodes: [ScanNode] = []
        var coverage = LocationCoverage()
        func add(
            _ parent: Int?, _ name: String, _ kind: NodeKind, logical: UInt64 = 0, allocated: UInt64 = 0,
            issue: CoverageIssue? = nil, owner: Int? = nil
        ) -> Int {
            let id = nodes.count
            nodes.append(
                ScanNode(
                    id: id, parent: parent, name: name, kind: kind, logicalBytes: logical,
                    allocatedBytes: allocated, allocationUnknown: issue != nil, hardLinkOwner: owner,
                    issue: issue, device: 1, inode: UInt64(owner ?? id)))
            if kind == .directory || kind == .package { coverage.enumeration[id] = .enumerated }
            if let issue {
                coverage.record(path: "/Synthetic/" + name, nodeID: id, operation: .metadata, reason: issue)
            }
            return id
        }
        let root = add(nil, "Example", .directory)
        if scenario != .empty {
            let library = add(root, "Library", .directory)
            let package = add(root, "Example.app", .package)
            let deep = add(root, "Deep", .directory)
            let owner = add(root, "Archive", .file, logical: 4096, allocated: 4096)
            _ = add(root, "Archive link", .file, owner: owner)
            _ = add(root, "Sparse image", .file, logical: 1 << 30, allocated: 8192)
            _ = add(root, String(repeating: "long-name-", count: 20), .file, logical: 17, allocated: 4096)
            if scenario == .limited {
                _ = add(root, "Denied", .directory, issue: .denied)
                _ = add(root, "Placeholder", .file, logical: 500_000, issue: .placeholder)
                _ = add(root, "Excluded mount", .directory, issue: .volumeBoundary)
            }
            for index in 0..<300 { _ = add(root, "Small \(index)", .file, logical: 1, allocated: 4096) }
            let support = add(library, "Application Support", .directory)
            _ = add(package, "Executable", .file, logical: 1000, allocated: 4096)
            var cursor = deep
            for _ in 0..<32 { cursor = add(cursor, "Nested", .directory) }
            _ = add(support, "Managed data", .file, logical: 5000, allocated: 8192)
            if scenario == .scanning || scenario == .cancelled {
                coverage.enumeration[deep] = scenario == .scanning ? .partial : .cancelled
                coverage.enumeration[cursor] = .unopened
            }
        }
        var navigation = ProgressiveIndex()
        for node in nodes {
            navigation.append(node)
            navigation.attribute(
                logical: node.logicalBytes, allocated: node.allocatedBytes, to: node.parent, nodes: nodes)
        }
        var progress = ScanProgress()
        progress.entries = UInt64(nodes.count - 1)
        progress.logicalBytes = nodes.reduce(0) { $0 + $1.logicalBytes }
        progress.allocatedBytes = nodes.reduce(0) { $0 + $1.allocatedBytes }
        progress.hardLinks = scenario == .empty ? 0 : 1
        for record in coverage.records { progress.issues[record.reason, default: 0] += record.count }
        switch scenario {
        case .scanning: progress.state = .scanning
        case .cancelled: progress.state = .cancelled
        case .limited: progress.state = .limited
        default: progress.state = .completed
        }
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let roots = [URL(fileURLWithPath: "/Users/Example")]
        if scenario != .scanning {
            Scanner.finalizeCoverage(nodes: &nodes, coverage: coverage)
        } else {
            for id in nodes.indices where coverage.enumeration[id] != nil {
                nodes[id].logicalBytes = navigation.totals[id]?.logical ?? 0
                nodes[id].allocatedBytes = navigation.totals[id]?.allocated ?? 0
                nodes[id].allocationUnknown = true
            }
        }
        let snapshot = navigation.snapshot(
            scanID: id, revision: 1, request: ScopeRequest(parent: 0), nodes: nodes,
            urls: roots, coverage: coverage, progress: progress, includeTreemap: true)
        let result = ScanResult(
            id: id, started: date, ended: date.addingTimeInterval(1), roots: roots, nodes: nodes,
            progress: progress, coverage: coverage, volumes: [])
        return PresentationFixture(
            result: result, snapshot: snapshot, freshness: scenario == .stale ? .stale : .current)
    }
}

extension PresentationFixtures {
    /// A deterministic synthetic disk with a realistic spread: a few huge files, heavy packages and caches, thousands of
    /// mid-size media files, long tails of tiny files, an unreadable folder, a cloud placeholder and a hard link.
    /// No filesystem access; names are invented. `tailFiles` scales the number of small files.
    public static func storageMap(tailFiles: Int = 4000) -> ScanResult {
        var nodes: [ScanNode] = []
        var coverage = LocationCoverage()
        var seed: UInt64 = 0x5EED_5AFE
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed >> 33
        }
        func pick(_ low: UInt64, _ high: UInt64) -> UInt64 { low + next() % (high - low + 1) }
        func blocks(_ bytes: UInt64) -> UInt64 { (bytes + 4095) / 4096 * 4096 }
        @discardableResult func add(
            _ parent: Int?, _ name: String, _ kind: NodeKind, bytes: UInt64 = 0, issue: CoverageIssue? = nil,
            allocated: UInt64? = nil, owner: Int? = nil
        ) -> Int {
            let id = nodes.count
            nodes.append(
                ScanNode(
                    id: id, parent: parent, name: name, kind: kind, logicalBytes: bytes,
                    allocatedBytes: owner == nil && issue == nil ? (allocated ?? blocks(bytes)) : 0,
                    allocationUnknown: issue != nil, hardLinkOwner: owner, issue: issue, device: 1,
                    inode: UInt64(owner ?? id)))
            if kind == .directory || kind == .package { coverage.enumeration[id] = terminalState(after: issue) }
            if let issue {
                coverage.record(path: "/Synthetic/" + name, nodeID: id, operation: .metadata, reason: issue)
            }
            return id
        }
        let gb: UInt64 = 1_000_000_000
        let mb: UInt64 = 1_000_000
        let kb: UInt64 = 1_000
        let root = add(nil, "Macintosh HD (example)", .directory)
        let users = add(root, "Users", .directory)
        let home = add(users, "example", .directory)

        let movies = add(home, "Movies", .directory)
        for (index, size) in [38, 24, 19, 11, 9, 7, 5, 4, 3].enumerated() {
            add(movies, "Project \(index + 1) final.mov", .file, bytes: UInt64(size) * gb + pick(0, gb / 2))
        }
        for index in 0..<40 { add(movies, "Clip \(index).mp4", .file, bytes: pick(80, 900) * mb) }
        let pictures = add(home, "Pictures", .directory)
        add(pictures, "Photos Library.photoslibrary", .package, bytes: 61 * gb + 400 * mb)
        let shoots = add(pictures, "Shoots", .directory)
        for shoot in 0..<24 {
            let folder = add(shoots, "2026-\(String(format: "%02d", shoot % 12 + 1)) Shoot \(shoot)", .directory)
            for photo in 0..<max(8, tailFiles / 300) {
                add(folder, "IMG_\(1000 + photo).\(photo % 5 == 0 ? "heic" : "jpg")", .file, bytes: pick(2, 12) * mb)
            }
        }
        let documents = add(home, "Documents", .directory)
        for index in 0..<60 {
            add(
                documents, "Report \(index).\(["pdf", "docx", "pages", "xlsx"][index % 4])", .file,
                bytes: pick(40, 9000) * kb)
        }
        add(documents, "Archive 2019.zip", .file, bytes: 7 * gb + 100 * mb)
        let downloads = add(home, "Downloads", .directory)
        add(downloads, "macOS Installer.dmg", .file, bytes: 15 * gb + 200 * mb)
        add(downloads, "Ubuntu.iso", .file, bytes: 4 * gb + 700 * mb)
        for index in 0..<50 {
            add(
                downloads, "download-\(index).\(["zip", "pdf", "dmg", "pkg"][index % 4])", .file,
                bytes: pick(1, 900) * mb)
        }
        let music = add(home, "Music", .directory)
        for index in 0..<max(80, tailFiles / 25) { add(music, "Track \(index).m4a", .file, bytes: pick(3, 14) * mb) }
        let dev = add(home, "Developer", .directory)
        for project in ["web-shop", "mobile-app", "data-pipeline", "game-prototype"] {
            let folder = add(dev, project, .directory)
            let modules = add(folder, "node_modules", .directory)
            for index in 0..<max(60, tailFiles / 12) {
                add(modules, "pkg-\(index)/index.js", .file, bytes: pick(1, 400) * kb)
            }
            let git = add(folder, ".git", .directory)
            add(git, "pack-a1b2c3.pack", .file, bytes: pick(200, 1800) * mb)
            let sources = add(folder, "Sources", .directory)
            for index in 0..<max(40, tailFiles / 40) {
                add(sources, "File\(index).swift", .file, bytes: pick(1, 60) * kb)
            }
        }
        let library = add(home, "Library", .directory)
        let caches = add(library, "Caches", .directory)
        let derived = add(caches, "Xcode DerivedData", .directory)
        for index in 0..<14 { add(derived, "Build-\(index).o", .file, bytes: pick(200, 1400) * mb) }
        for index in 0..<max(40, tailFiles / 30) { add(caches, "cache-\(index).db", .file, bytes: pick(1, 90) * mb) }
        let support = add(library, "Application Support", .directory)
        let slack = add(support, "Slack", .directory)
        for index in 0..<30 { add(slack, "blob-\(index).sqlite", .file, bytes: pick(5, 120) * mb) }
        let containers = add(library, "Containers", .directory)
        add(containers, "Docker.raw", .file, bytes: 128 * gb, allocated: 46 * gb)
        add(library, "Mail Downloads", .directory, issue: .denied)
        add(home, "Cloud Notes.pdf", .file, bytes: 480 * mb, issue: .placeholder)

        let applications = add(root, "Applications", .directory)
        for (name, size) in [
            ("Xcode.app", 16 * gb), ("Final Cut Pro.app", 4 * gb), ("Logic Pro.app", 3 * gb), ("Safari.app", 120 * mb),
            ("Notes.app", 25 * mb),
        ] {
            add(applications, name, .package, bytes: size + pick(0, 300) * mb)
        }
        let system = add(root, "System", .directory)
        let frameworks = add(system, "Library", .directory)
        for index in 0..<max(50, tailFiles / 40) {
            add(frameworks, "Framework\(index).dylib", .file, bytes: pick(1, 40) * mb)
        }
        let priv = add(root, "private", .directory)
        let vm = add(priv, "var", .directory)
        add(vm, "sleepimage", .file, bytes: 17 * gb)
        add(vm, "swapfile0", .file, bytes: 2 * gb)
        let tail = add(root, "opt", .directory)
        for index in 0..<tailFiles { add(tail, "item-\(index).dat", .file, bytes: pick(1, 300) * kb) }
        let archive = add(users, "Shared", .directory)
        let owner = add(archive, "Shared.mov", .file, bytes: 2 * gb)
        add(archive, "Shared link.mov", .file, owner: owner)
        add(root, "Link to home", .symbolicLink)

        Scanner.finalizeCoverage(nodes: &nodes, coverage: coverage)
        var progress = ScanProgress()
        progress.entries = UInt64(nodes.count - 1)
        progress.logicalBytes = nodes[0].logicalBytes
        progress.allocatedBytes = nodes[0].allocatedBytes
        progress.hardLinks = 1
        progress.symbolicLinks = 1
        for record in coverage.records { progress.issues[record.reason, default: 0] += record.count }
        progress.state = .limited
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return ScanResult(
            id: UUID(), started: date, ended: date.addingTimeInterval(42),
            roots: [URL(fileURLWithPath: "/Users/Example")],
            nodes: nodes, progress: progress, coverage: coverage, volumes: [])
    }
}

extension PresentationFixtures {
    /// A synthetic whole-drive scan: the sealed System volume at /, the Data volume, and two auxiliary volumes, as
    /// separate roots exactly as the scanner produces them. Firm-linked folders appear on the System side as
    /// zero-byte boundary stubs; /System, /System/Library, /usr and /private are real on both volumes and must merge.
    /// No filesystem access; every name is invented.
    public static func wholeDrive(tailFiles: Int = 1200) -> ScanResult {
        var nodes: [ScanNode] = []
        var coverage = LocationCoverage(wholeDrive: true)
        var seed: UInt64 = 0xD217_E5EE
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed >> 33
        }
        func pick(_ low: UInt64, _ high: UInt64) -> UInt64 { low + next() % (high - low + 1) }
        func blocks(_ bytes: UInt64) -> UInt64 { (bytes + 4095) / 4096 * 4096 }
        @discardableResult func add(
            _ parent: Int?, _ name: String, _ kind: NodeKind, bytes: UInt64 = 0, issue: CoverageIssue? = nil,
            allocated: UInt64? = nil
        ) -> Int {
            let id = nodes.count
            let sized = issue == nil
            nodes.append(
                ScanNode(
                    id: id, parent: parent, name: name, kind: kind, logicalBytes: sized ? bytes : 0,
                    allocatedBytes: sized ? (allocated ?? blocks(bytes)) : 0,
                    allocationUnknown: issue != nil && issue != .volumeBoundary, issue: issue, device: 1,
                    inode: UInt64(id)))
            if kind == .directory || kind == .package { coverage.enumeration[id] = terminalState(after: issue) }
            if let issue {
                coverage.record(path: "/Synthetic/" + name, nodeID: id, operation: .traverse, reason: issue)
            }
            return id
        }
        let gb: UInt64 = 1_000_000_000
        let mb: UInt64 = 1_000_000
        let kb: UInt64 = 1_000
        /// A package is a node that owns files, as the scanner records bundles.
        func package(_ parent: Int, _ name: String, bytes: UInt64) {
            let id = add(parent, name, .package)
            add(id, "Contents.bin", .file, bytes: bytes)
        }
        // Sealed System volume at "/".
        let system = add(nil, "/", .directory)
        let systemFolder = add(system, "System", .directory)
        let systemLibrary = add(systemFolder, "Library", .directory)
        let frameworks = add(systemLibrary, "Frameworks", .directory)
        for index in 0..<max(40, tailFiles / 30) {
            add(frameworks, "Framework\(index).dylib", .file, bytes: pick(1, 25) * mb)
        }
        add(systemLibrary, "dyld-shared-cache", .file, bytes: 4 * gb + 200 * mb)
        add(systemLibrary, "Caches", .directory, issue: .volumeBoundary)  // firm-link stub
        add(systemFolder, "Cryptexes", .directory, bytes: 0)
        let usr = add(system, "usr", .directory)
        let usrLib = add(usr, "lib", .directory)
        for index in 0..<30 { add(usrLib, "lib\(index).dylib", .file, bytes: pick(1, 12) * mb) }
        add(usr, "local", .directory, issue: .volumeBoundary)
        let bin = add(system, "bin", .directory)
        for index in 0..<20 { add(bin, "tool\(index)", .file, bytes: pick(50, 900) * kb) }
        let systemPrivate = add(system, "private", .directory)
        add(systemPrivate, "var", .directory, issue: .volumeBoundary)
        for stub in ["Users", "Applications", "Library", "opt"] {
            add(system, stub, .directory, issue: .volumeBoundary)
        }
        // Writable Data volume.
        let data = add(nil, "/System/Volumes/Data", .directory)
        let users = add(data, "Users", .directory)
        let home = add(users, "example", .directory)
        let movies = add(home, "Movies", .directory)
        for (index, size) in [30, 18, 12, 8, 5].enumerated() {
            add(movies, "Project \(index + 1).mov", .file, bytes: UInt64(size) * gb + pick(0, gb / 2))
        }
        let pictures = add(home, "Pictures", .directory)
        package(pictures, "Photos Library.photoslibrary", bytes: 52 * gb)
        for index in 0..<max(60, tailFiles / 20) {
            add(pictures, "IMG_\(index).\(index % 4 == 0 ? "heic" : "jpg")", .file, bytes: pick(2, 14) * mb)
        }
        let documents = add(home, "Documents", .directory)
        for index in 0..<60 {
            add(
                documents, "Report \(index).\(["pdf", "docx", "xlsx", "pages"][index % 4])", .file,
                bytes: pick(60, 6000) * kb)
        }
        add(documents, "Archive.zip", .file, bytes: 6 * gb)
        let downloads = add(home, "Downloads", .directory)
        add(downloads, "Installer.dmg", .file, bytes: 13 * gb)
        add(downloads, "Linux.iso", .file, bytes: 4 * gb)
        let developer = add(home, "Developer", .directory)
        for project in ["web-shop", "mobile-app"] {
            let folder = add(developer, project, .directory)
            let modules = add(folder, "node_modules", .directory)
            for index in 0..<max(50, tailFiles / 10) {
                add(modules, "pkg-\(index).js", .file, bytes: pick(1, 300) * kb)
            }
        }
        let library = add(home, "Library", .directory)
        let support = add(library, "Application Support", .directory)
        for index in 0..<24 { add(support, "store-\(index).sqlite", .file, bytes: pick(8, 140) * mb) }
        add(library, "Mail", .directory, issue: .denied)
        let containers = add(library, "Containers", .directory)
        add(containers, "Docker.raw", .file, bytes: 96 * gb, allocated: 38 * gb)
        let applications = add(data, "Applications", .directory)
        for (name, size) in [("Xcode.app", 16 * gb), ("Final Cut Pro.app", 4 * gb), ("Safari.app", 120 * mb)] {
            package(applications, name, bytes: size)
        }
        let sharedLibrary = add(data, "Library", .directory)
        let logs = add(sharedLibrary, "Logs", .directory)
        for index in 0..<40 { add(logs, "log-\(index).txt", .file, bytes: pick(1, 900) * kb) }
        let dataSystem = add(data, "System", .directory)
        let dataSystemLibrary = add(dataSystem, "Library", .directory)
        let assets = add(dataSystemLibrary, "AssetsV2", .directory)
        for index in 0..<max(30, tailFiles / 40) { add(assets, "asset-\(index).bin", .file, bytes: pick(20, 240) * mb) }
        add(dataSystemLibrary, "Caches", .directory)
        let dataUsr = add(data, "usr", .directory)
        let dataLocal = add(dataUsr, "local", .directory)
        for index in 0..<24 { add(dataLocal, "brew-\(index).dylib", .file, bytes: pick(1, 40) * mb) }
        let dataPrivate = add(data, "private", .directory)
        let dataVar = add(dataPrivate, "var", .directory)
        add(dataVar, "folders", .directory, bytes: 0)
        let dataDB = add(dataVar, "db", .directory)
        add(dataDB, "protected", .directory, issue: .denied)
        for index in 0..<40 { add(dataDB, "index-\(index).db", .file, bytes: pick(1, 80) * mb) }
        add(data, "opt", .directory)
        // Auxiliary volumes.
        let vm = add(nil, "/System/Volumes/VM", .directory)
        add(vm, "swapfile0", .file, bytes: 2 * gb)
        add(vm, "swapfile1", .file, bytes: 2 * gb)
        add(vm, "sleepimage", .file, bytes: 17 * gb)
        let preboot = add(nil, "/System/Volumes/Preboot", .directory)
        for index in 0..<12 { add(preboot, "boot-\(index).img", .file, bytes: pick(10, 120) * mb) }

        // The scanner lists each directory's children contiguously; reorder so the live index can ingest the fixture.
        (nodes, coverage) = breadthFirst(nodes: nodes, coverage: coverage)
        Scanner.finalizeCoverage(nodes: &nodes, coverage: coverage)
        var progress = ScanProgress()
        progress.entries = UInt64(nodes.count)
        progress.logicalBytes = nodes.filter { $0.parent == nil }.reduce(0) { $0 + $1.logicalBytes }
        progress.allocatedBytes = nodes.filter { $0.parent == nil }.reduce(0) { $0 + $1.allocatedBytes }
        for record in coverage.records { progress.issues[record.reason, default: 0] += record.count }
        progress.state = .limited
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return ScanResult(
            id: UUID(), started: date, ended: date.addingTimeInterval(180),
            roots: [
                URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/System/Volumes/Data"),
                URL(fileURLWithPath: "/System/Volumes/VM"), URL(fileURLWithPath: "/System/Volumes/Preboot"),
            ],
            nodes: nodes, progress: progress, coverage: coverage, volumes: [])
    }
}

extension PresentationFixtures {
    /// Re-number nodes breadth first so every directory's children are contiguous, as the real scanner produces them.
    static func breadthFirst(nodes: [ScanNode], coverage: LocationCoverage) -> ([ScanNode], LocationCoverage) {
        var children: [Int: [Int]] = [:]
        var roots: [Int] = []
        for node in nodes {
            if let parent = node.parent { children[parent, default: []].append(node.id) } else { roots.append(node.id) }
        }
        var order = roots
        var head = 0
        while head < order.count {
            order += children[order[head]] ?? []
            head += 1
        }
        var newID = [Int](repeating: 0, count: nodes.count)
        for (position, old) in order.enumerated() { newID[old] = position }
        var out: [ScanNode] = []
        for old in order {
            var node = nodes[old]
            node.id = newID[old]
            node.parent = node.parent.map { newID[$0] }
            node.hardLinkOwner = node.hardLinkOwner.map { newID[$0] }
            out.append(node)
        }
        var moved = LocationCoverage(limit: coverage.limit, wholeDrive: coverage.wholeDrive)
        for record in coverage.records {
            for _ in 0..<record.count {
                moved.record(
                    path: record.path, nodeID: record.nodeID.map { newID[$0] }, operation: record.operation,
                    reason: record.reason,
                    parentID: record.parentID.map { newID[$0] }, policyDetail: record.policyDetail)
            }
        }
        for (old, state) in coverage.enumeration { moved.enumeration[newID[old]] = state }
        return (out, moved)
    }
}

extension PresentationFixtures {
    /// The whole-drive fixture as a live (scanning) checkpoint at the unified top level: totals are lower bounds and the
    /// folders that are still being read are flagged, exactly as the scanner publishes them.
    public static func wholeDriveLive() -> (snapshot: ScopeSnapshot, result: ScanResult) {
        let result = wholeDrive()
        var index = ProgressiveIndex()
        for node in result.nodes { index.append(node) }
        for node in result.nodes {
            index.attribute(
                logical: node.logicalBytes, allocated: node.allocatedBytes, to: node.parent, nodes: result.nodes)
        }
        var progress = result.progress
        progress.state = .scanning
        let snapshot = index.snapshot(
            scanID: UUID(), revision: 1, request: ScopeRequest(parent: nil, wantsTreemap: true), nodes: result.nodes,
            urls: result.roots, coverage: result.coverage, progress: progress, includeTreemap: true)
        return (snapshot, result)
    }
}

/// The listing state a scanner leaves on a folder: listed to the end, or the terminal state its issue implies.
private func terminalState(after issue: CoverageIssue?) -> DirectoryEnumeration {
    switch issue {
    case nil: .enumerated
    case .policyExcluded?, .volumeBoundary?, .placeholder?: .skipped
    case .enumeration?: .listingFailed
    case .some: .openFailed
    }
}
