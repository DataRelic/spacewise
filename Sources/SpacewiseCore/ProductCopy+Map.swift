import Foundation

extension ProductCopy {
    /// The file-type list beside the storage map.
    public enum FileTypes {
        public static let title = "File Types"
        public static let accessibility = "File Types"
        public static let help =
            "Select a type to highlight its tiles on the map and dim the rest. Select it again, or press Esc, to clear."
        public static let show = "Show File Types"
        public static let hide = "Hide File Types"
        public static func toggleTip(_ label: String) -> String { label }
        /// The count under a row. Folder blocks are counted as folders; everything else as items.
        public static func items(_ count: Int, folders: Bool) -> String {
            let number = SizeFormat.count(UInt64(count))
            if folders { return "\(number) \(count == 1 ? "folder" : "folders")" }
            return "\(number) \(count == 1 ? "item" : "items")"
        }
        public static func share(_ share: Double) -> String { ShareFormat.percent(share) }
        /// What VoiceOver reads for a row.
        public static func row(_ name: String, size: String, items: String, share: Double) -> String {
            "\(name), \(size), \(items), \(ShareFormat.spoken(share)) of allocated space shown on the map"
        }
    }

    /// Map accessibility beyond the tile details.
    public enum MapAccess {
        public static func value(summary: String, exposed: Int, total: Int) -> String {
            let count = SizeFormat.count(UInt64(exposed))
            let available = exposed == total ? count : "\(count) of \(SizeFormat.count(UInt64(total)))"
            return "\(summary). \(available) map \(total == 1 ? "tile" : "tiles") available at this level."
        }
        /// A tile's place among its siblings in the folder that holds it, so the count is always exact.
        public static func tile(_ detail: String, position: Int, of count: Int) -> String {
            "\(detail), \(position) of \(count)"
        }
        /// Shown when only the largest children of a folder are reachable from the map.
        public static func overflow(_ count: Int, nested: Bool) -> String {
            let tiles = count == 1 ? "map tile" : "map tiles"
            let scope =
                nested ? "Zoom into this folder, then show the Item List." : "Show the Item List for this scope."
            return
                "\(SizeFormat.count(UInt64(count))) more \(tiles) at this level. \(scope) Clear any filter and check other pages during a scan."
        }
        public static let select = "Select"
        public static let zoomIn = Map.menuZoomIn
        public static let showInFinder = "Show in Finder"
    }
}
