import Foundation

// Text for the commands, list columns, inspector fields and windows. Commands are in title case,
// sentences in sentence case. The wording of the app's other strings lives in ProductCopy+Screens.swift.
extension ProductCopy {
    /// Labels for menu and context-menu items.
    public enum Commands {
        public static let open = "Open"
        public static let quickLook = "Quick Look"
        public static let cut = "Cut"
        public static let paste = "Paste"
        public static let selectAll = "Select All"
        public static let filter = "Filter by Name"
        public static let enterFullScreen = "Enter Full Screen"
        public static let columns = "Columns"
    }

    /// The list's name filter in the toolbar.
    public enum Filter {
        public static let label = "Filter"
        public static let placeholder = "Filter by name"
        public static let tip = "Filter direct entries by name. During a scan, matches are shown page by page (⌘F)."
        public static let noMatchesTitle = "No matches"
        public static func noMatchesDetail(_ text: String, live: Bool) -> String {
            let scope = live ? "on this scan page" : "directly in this scope"
            return "No entry \(scope) has “\(text)” in its name."
        }
    }

    /// The list's Items column.
    public enum ItemsColumn {
        public static let title = "Items"
        public static let tip = "Number of items directly inside a folder or package."
        public static let unknown = "—"
        public static func spoken(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }
    }

    /// Short labels and values in the inspector, and the explanations behind its disclosure.
    public enum InspectorFields {
        public static let kind = "Kind"
        public static let size = "Size"
        public static let logical = "Logical size"
        public static let share = "Share"
        public static let items = "Items"
        public static let location = "Location"
        public static let coverage = "Read"
        public static let classification = "Managed by"
        public static let hardLink = "Hard link"
        public static func hardLinkOwner(_ name: String) -> String { "Counted at “\(name)”" }
        public static let hardLinkElsewhere = "Counted at another path"
        public static let measured = "Measured"

        public static let about = "About these fields"
        public static let aboutSizes = "Sizes"
        public static func exactSizes(allocated: String, logical: String) -> String {
            "Size is the space on disk: \(allocated). Logical size is the length the item reports: \(logical)."
        }
        public static let logicalLarger =
            "Logical size is larger than the space on disk because of sparse, compressed or cloned data."
        public static let logicalSmaller =
            "Logical size is smaller than the space on disk because of block rounding and metadata."
        public static let lowerBound = "Some contents weren’t measured, so the size is at least this much."
        public static let aboutCoverage = "Read"
        public static func coverageReason(_ reason: String) -> String { "Reason: \(reason)." }
        public static let aboutClassification = "Managed by"
        public static let aboutOperations = "Actions"
        public static let aboutScanning = "While scanning"
        public static let scanning = "Sizes and hard-link owners can still change until the scan finishes."
    }

    /// The About panel.
    public enum About {
        /// Shown in place of a version number when the app runs from the build folder rather than an app bundle.
        public static let unbundledVersion = "Development build"
    }
}
