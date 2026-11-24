import Foundation

/// File-type colour groups plus two structural groups that are not file types.
public enum FileCategory: Int, CaseIterable, Sendable {
    case video, audio, images, documents, archives, diskImages, code, applications, databases, other
    /// A folder drawn as one block because the tile budget ended before its contents were expanded.
    case folderBlock
    /// An "N smaller items" tile: several items summed into one area.
    case grouped
    /// Legend-only: leaves inside the system-managed group. Never a file type; tiles keep their real type.
    case managedZone

    public var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .images: "Images"
        case .documents: "Documents"
        case .archives: "Archives"
        case .diskImages: "Disk images & VMs"
        case .code: "Code & developer"
        case .applications: "Apps & bundles"
        case .databases: "Databases"
        case .other: "Other files"
        case .folderBlock: "Folders not opened"
        case .grouped: "Smaller items"
        case .managedZone: "Managed by macOS"
        }
    }

    private static let extensions: [String: FileCategory] = {
        var table: [String: FileCategory] = [:]
        func add(_ category: FileCategory, _ names: String) {
            for name in names.split(separator: " ") { table[String(name)] = category }
        }
        add(.video, "mov mp4 m4v avi mkv webm mpg mpeg wmv flv mts m2ts prores braw r3d")
        add(.audio, "mp3 m4a aac wav aif aiff flac ogg opus caf wma mid midi band logicx")
        add(.images, "jpg jpeg png heic heif gif tif tiff cr2 cr3 nef arw dng psd psb ai svg webp bmp ico icns exr xcf")
        add(.images, "sketch fig")
        add(.documents, "pdf doc docx pages key numbers xls xlsx ppt pptx txt rtf md csv epub odt ods odp tex log")
        add(.archives, "zip tar gz tgz bz2 xz zst 7z rar pkg xip cab lzma lz4 whl")
        add(.diskImages, "dmg iso img sparseimage sparsebundle vmdk vdi qcow qcow2 vhd vhdx hdd pvm vmwarevm")
        add(.code, "swift m mm h hpp c cc cpp cxx rs go py pyc js mjs cjs ts tsx jsx java kt kts rb php cs o a lib obj")
        add(
            .code,
            "dylib so class jar json yaml yml toml xml html htm css scss map swiftmodule swiftdoc swiftsourceinfo")
        add(.code, "d dia pbxproj xcassets strings plist wasm")
        add(.databases, "sqlite sqlite3 db mdb accdb realm store sqlitedb wal shm ldb parquet arrow lmdb mdf ndf")
        add(.databases, "emlx mbox")
        return table
    }()
    private static let bundleApplications: Set<String> = [
        "app", "framework", "xpc", "appex", "plugin", "bundle", "kext", "prefpane", "saver", "component", "dsym",
        "xcarchive",
    ]

    /// Classifies by name and kind only. Never reads contents.
    public static func category(name: String, kind: NodeKind) -> FileCategory {
        guard let dot = name.utf8.lastIndex(of: UInt8(ascii: ".")), dot != name.utf8.startIndex else {
            return .other
        }
        let ext = name[name.utf8.index(after: dot)...].lowercased()
        if kind == .package {
            if bundleApplications.contains(ext) { return .applications }
            if ext == "sparsebundle" || ext == "sparseimage" { return .diskImages }
            if ext == "photoslibrary" { return .images }
            return .other
        }
        return extensions[ext] ?? .other
    }
}
