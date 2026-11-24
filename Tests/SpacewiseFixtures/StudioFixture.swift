import Foundation
import SpacewiseCore

extension PresentationFixtures {
    /// A deterministic synthetic workstation that uses every file type: video and audio production, a photo library of
    /// raw files, documents, software projects with build products, databases, virtual machines and backups, nested
    /// several folders deep, with a few very large files among thousands of small ones. It exists so the storage map
    /// and its file-type list can be judged on a varied disk. No filesystem access; names are invented.
    public static func studio(scale: Int = 1) -> ScanResult {
        let scale = max(1, scale)
        var nodes: [ScanNode] = []
        var seed: UInt64 = 0x57D1_0F1E
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed >> 33
        }
        func pick(_ low: UInt64, _ high: UInt64) -> UInt64 { low + next() % (high - low + 1) }
        func blocks(_ bytes: UInt64) -> UInt64 { (bytes + 4095) / 4096 * 4096 }
        @discardableResult
        func add(_ parent: Int?, _ name: String, _ kind: NodeKind = .directory, bytes: UInt64 = 0) -> Int {
            let id = nodes.count
            nodes.append(
                ScanNode(
                    id: id, parent: parent, name: name, kind: kind, logicalBytes: bytes,
                    allocatedBytes: blocks(bytes), device: 1, inode: UInt64(id + 1)))
            return id
        }
        func files(_ parent: Int, _ count: Int, _ name: (Int) -> String, _ low: UInt64, _ high: UInt64) {
            for index in 0..<count { add(parent, name(index), .file, bytes: pick(low, high)) }
        }
        let gb: UInt64 = 1_000_000_000
        let mb: UInt64 = 1_000_000
        let kb: UInt64 = 1_000
        let root = add(nil, "Studio (example)")
        let home = add(add(root, "Users"), "alex")

        // Video production: a couple of huge masters, interview rushes and many proxies.
        let movies = add(home, "Movies")
        let film = add(movies, "Harbour Documentary")
        add(film, "Master 4K ProRes.mov", .file, bytes: 58 * gb)
        add(film, "Master HD.mp4", .file, bytes: 9 * gb)
        let rushes = add(film, "Rushes")
        for day in 1...6 {
            files(add(rushes, "Day \(day)"), 6, { "A\(day)_\(String(format: "%03d", $0)).mov" }, 1 * gb, 6 * gb)
        }
        files(add(film, "Proxies"), 120 * scale, { "proxy-\($0).mp4" }, 40 * mb, 260 * mb)
        files(add(movies, "Phone"), 80 * scale, { "VID_\(2000 + $0).mov" }, 30 * mb, 900 * mb)

        // Audio: a sample library, project stems and a music collection.
        let music = add(home, "Music")
        let samples = add(music, "Sample Library")
        for pack in ["Drums", "Strings", "Synths", "Foley"] {
            files(add(samples, pack), 90 * scale, { "\(pack.lowercased())-\($0).wav" }, 2 * mb, 60 * mb)
        }
        let projects = add(music, "Logic Projects")
        for song in ["Tide", "Night Ferry", "Gulls"] {
            files(add(projects, song), 24, { "stem \($0).aif" }, 50 * mb, 400 * mb)
        }
        files(add(music, "Collection"), 300 * scale, { "Track \($0).m4a" }, 3 * mb, 15 * mb)

        // Photography: raw files by year and month, layered edits, exports.
        let pictures = add(home, "Pictures")
        let raw = add(pictures, "Raw")
        for year in [2024, 2025, 2026] {
            let folder = add(raw, "\(year)")
            for month in 1...6 {
                files(
                    add(folder, String(format: "%02d", month)), 30 * scale,
                    { "DSC\(year % 100)\(month)\($0).\(["cr3", "nef", "dng"][$0 % 3])" }, 22 * mb, 70 * mb)
            }
        }
        files(add(pictures, "Edits"), 40, { "edit-\($0).psd" }, 200 * mb, 2 * gb)
        files(add(pictures, "Exports"), 400 * scale, { "export-\($0).jpg" }, 2 * mb, 9 * mb)

        // Documents: a thesis several folders deep, office files, books.
        let documents = add(home, "Documents")
        let thesis = add(add(add(documents, "University"), "Thesis"), "Chapters")
        files(thesis, 30, { "chapter-\($0).\(["pages", "pdf", "md"][$0 % 3])" }, 200 * kb, 90 * mb)
        files(
            add(documents, "Work"), 200 * scale, { "file-\($0).\(["docx", "xlsx", "key", "pdf"][$0 % 4])" },
            100 * kb, 140 * mb)
        files(add(documents, "Books"), 60, { "book-\($0).epub" }, 1 * mb, 40 * mb)

        // Software: repositories with sources, dependencies, git packs and build products; a container disk and VMs.
        let developer = add(home, "Developer")
        for repo in ["harbour-app", "tide-server", "gull-ml", "site"] {
            let folder = add(developer, repo)
            files(
                add(folder, "Sources"), 120 * scale, { "Source\($0).\(["swift", "ts", "py", "go"][$0 % 4])" },
                2 * kb, 90 * kb)
            files(add(folder, "node_modules"), 300 * scale, { "module-\($0).js" }, 1 * kb, 600 * kb)
            add(add(folder, ".git"), "pack-\(repo).pack", .file, bytes: pick(300, 2400) * mb)
            files(add(folder, "build"), 40, { "object-\($0).o" }, 1 * mb, 60 * mb)
        }
        let machines = add(developer, "Virtual Machines")
        add(machines, "Windows 11.vmdk", .file, bytes: 64 * gb)
        add(machines, "Ubuntu Server.qcow2", .file, bytes: 21 * gb)
        add(add(add(home, "Library"), "Containers"), "Docker.raw", .file, bytes: 38 * gb)

        // Data: a local database server, analytics extracts and app databases.
        let data = add(home, "Data")
        files(add(data, "postgres"), 40, { "relation-\($0).db" }, 100 * mb, 1 * gb)
        files(add(data, "Analytics"), 12, { "events-\($0).parquet" }, 400 * mb, 3 * gb)
        files(add(data, "App Stores"), 60, { "store-\($0).sqlite" }, 1 * mb, 200 * mb)

        // Backups and downloads.
        let backups = add(home, "Backups")
        add(backups, "Laptop 2025.sparsebundle", .package, bytes: 46 * gb)
        files(backups, 16, { "backup-\($0).\(["zip", "tar.gz", "7z", "xz"][$0 % 4])" }, 600 * mb, 7 * gb)
        let downloads = add(home, "Downloads")
        add(downloads, "Installer.dmg", .file, bytes: 13 * gb)
        add(downloads, "ubuntu-26.04.iso", .file, bytes: 6 * gb)
        files(
            downloads, 80 * scale, { "download-\($0).\(["zip", "pdf", "dmg", "pkg", "png"][$0 % 5])" },
            1 * mb, 800 * mb)

        // Applications as packages, and a long tail of unrecognised files.
        let applications = add(root, "Applications")
        for (name, size) in [
            ("Final Cut Pro.app", 6 * gb), ("Logic Pro.app", 4 * gb), ("Xcode.app", 15 * gb),
            ("Photo Editor.app", 3 * gb), ("Browser.app", 600 * mb),
        ] {
            let package = add(applications, name, .package)
            add(package, "Contents", .file, bytes: size)
        }
        files(add(root, "opt"), 1500 * scale, { "item-\($0).dat" }, 1 * kb, 400 * kb)

        // Folder totals are summed bottom-up by finalizeCoverage (children always follow their parent here).
        var coverage = LocationCoverage()
        for node in nodes where node.kind == .directory || node.kind == .package {
            coverage.enumeration[node.id] = .enumerated
        }
        Scanner.finalizeCoverage(nodes: &nodes, coverage: coverage)
        var progress = ScanProgress()
        progress.entries = UInt64(nodes.count - 1)
        progress.logicalBytes = nodes[0].logicalBytes
        progress.allocatedBytes = nodes[0].allocatedBytes
        progress.state = .completed
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return ScanResult(
            id: UUID(), started: date, ended: date.addingTimeInterval(38),
            roots: [URL(fileURLWithPath: "/Users/Example")], nodes: nodes, progress: progress,
            coverage: coverage, volumes: [])
    }
}
