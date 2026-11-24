import Darwin

/// Pure policy makes placeholder behavior testable without fabricating a real cloud download.
public enum MetadataPolicy {
    public static func isPlaceholder(flags: UInt32) -> Bool { flags & UInt32(SF_DATALESS) != 0 }

    package static func kind(mode: mode_t, extension pathExtension: String) -> NodeKind {
        switch mode & S_IFMT {
        case S_IFDIR: packageExtension(pathExtension) ? .package : .directory
        case S_IFREG: .file
        case S_IFLNK: .symbolicLink
        default: .other
        }
    }
    public static func packageExtension(_ ext: String) -> Bool {
        [
            "app", "bundle", "framework", "photoslibrary", "photolibrary", "pkg", "playground", "rtfd", "pages",
            "numbers", "key",
        ].contains(ext.lowercased())
    }
}
