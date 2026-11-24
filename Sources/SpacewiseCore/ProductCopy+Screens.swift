import Foundation

// The app's user-facing text, screen by screen, kept apart from the AppKit controllers, menus and views so
// every string sits in one place. Each section belongs to one part of the window; the app's files say which one they
// read. Formats that only join other strings with punctuation ("Title. Detail") stay where they are used.
extension ProductCopy {
    /// The app itself: its name, the About panel, and the default scan's scope name.
    public enum App {
        public static let name = "Spacewise"
        public static let aboutCredits =
            "Shows what uses space on your disk. It reads names and sizes, never file contents, and can move eligible personal files to the Trash after confirmation."
    }

    /// Names of what is being scanned.
    public enum Scope {
        /// The main scan and the disk it covers.
        public static let startupDisk = "Startup Disk"
        /// The scope name of a chosen folder whose name cannot be read.
        public static let folder = "Folder"
    }

    /// The Ready screen shown before the first scan.
    public enum Ready {
        public static let title = "See what’s using space on your Mac"
        public static let subtitle = "Scan the whole startup disk, or one folder for a quicker look."
        public static let scanButton = "Scan Startup Disk"
        public static let scanButtonHelp = "Scan everything you can read on the startup disk"
        public static let folderButton = "Scan Folder…"
        /// VoiceOver help for Scan Folder…; its label is the button's own title, so Voice Control can say it.
        public static let folderButtonHelp = "Choose a folder to scan"
        public static let privacy =
            "Scanning reads names, sizes and filesystem metadata without reading file contents. macOS may ask for folder access."
        public static let accessibility = "Choose what to scan"
    }

    /// The scope header: breadcrumbs and the totals under them.
    public enum Header {
        public static let location = "Location"
        public static let hiddenCrumbs = "…"
        public static let hiddenCrumbsAccessibility = "Show hidden folders in this path"
        public static func currentFolder(_ name: String) -> String { "Current folder, \(name)" }
        public static func goTo(_ name: String) -> String { "Go to \(name)" }
        public static let allocated = "Size"
        public static let allocatedSoFar = "Size so far"
        public static let logical = "Logical size"
        public static let logicalSoFar = "Logical size so far"
        public static let items = "Direct entries"
        public static let itemsSoFar = "Direct entries found"
        public static let itemsHelp = "Entries directly in this scope, before filtering."
        public static let matches = "Matches"
        public static let matchesSoFar = "Matches so far"
    }

    /// The item list: its columns, cells and the footer under it.
    public enum List {
        public static let accessibility = "Item List"
        public static let nameTitle = "Name"
        public static let nameTip = "Folders and packages open with Return or a double-click."
        public static let allocatedTitle = "Size"
        public static let allocatedTip =
            "Space the item takes up on disk. ≥ means at least this much; Unknown means its contents weren’t read."
        public static let logicalTitle = "Logical Size"
        /// The one place the difference between the two sizes is explained in the list.
        public static let logicalTip =
            "The length the item reports. Sparse, compressed and cloned files take up less space on disk than this; block rounding makes small files take up more."
        public static let shareTitle = "Share"
        public static let shareTip = "Share of this folder’s size."
        public static let classificationTitle = "Managed By"
        public static let classificationTip =
            "Who manages the item. This says nothing about whether it’s safe to remove."
        public static let operationsTitle = "Actions"
        public static let operationsTip = "What Spacewise can do with the item."
        public static let shareCellTip = "Share of this folder’s size"
        /// The share column's text: one format everywhere (see `ShareFormat`).
        public static func share(_ share: Double) -> String { ShareFormat.percent(share) }
        public static let noShare = "—"
        public static let previousPage = "Previous Page"
        public static let nextPage = "Next Page"
        public static func livePage(_ page: Int, entries: Int?, matches: Int?) -> String {
            let prefix = "Scan page \(SizeFormat.count(UInt64(page)))"
            guard let entries else { return "\(prefix) · Loading entries…" }
            let count = SizeFormat.count(UInt64(entries))
            if let matches { return "\(prefix) · \(SizeFormat.count(UInt64(matches))) of \(count) entries match" }
            return "\(prefix) · \(count) \(entries == 1 ? "entry" : "entries") on this page"
        }
    }

    /// Buttons on the outcome and freshness banners.
    public enum BannerButtons {
        public static let stop = "Stop Scan"
        public static let scanDetails = "Scan Details…"
        public static let rescan = "Rescan"
        public static let privacySettings = "Open Privacy & Security Settings…"
        public static let privacySettingsHelp = "Open the Full Disk Access list in System Settings"
    }

    /// The inspector beside the list.
    public enum Inspector {
        public static let heading = "Inspector"
        public static func heading(_ title: String) -> String { "Inspector · \(title)" }
        public static let copyPath = "Copy Path"
        public static let showInFinder = "Show in Finder"
        public static let scanDetails = "Scan Details…"
        public static let selectionLabel = "Selection"
        public static let selectionHint = "Select an item to see its details."
        /// Title for a summed group of small items when its tile has no detail.
        public static let group = "Group"
        public static let managedGroupLocation = "A group, not one folder. Each item inside has its own location."
        public static let whatThisIsLabel = "What this is"
        public static let managedGroupWhatThisIs =
            "Folders and volumes that macOS manages, such as the system, swap and startup files. Open it to see each item and where it is."
        public static let measuredLabel = "Measured"
        public static func managedGroupMeasured(_ bytes: String, exact: String) -> String {
            "\(bytes) on disk across files (\(exact))"
        }
        public static let managedGroupNothingMeasured = "Nothing measured"
        public static let managedGroupLowerBoundEnding = ". Some areas couldn’t be read, so it’s at least this much."
        public static let managedGroupExactEnding = "."
        public static let notMeasuredLabel = "Not measured"
        public static let managedGroupNotMeasured =
            "Snapshots, shared APFS space and file system records have no per-file size, so Spacewise doesn’t show them."
        public static let physicalLocationsLabel = "Physical locations"
        public static let storedOnBothVolumesLabel = "Stored on both volumes"
        public static let physicalLocationLabel = "Physical location"
        public static func itemMissing(_ name: String) -> String {
            "“\(name)” is no longer at this location. Rescan to refresh."
        }
    }

    /// The storage map panel, its hover card and its context menu.
    public enum Map {
        public static let title = "Storage map"
        public static let accessibilityHelp =
            "Tile area represents allocated disk space. Arrow keys move between tiles. Use the Item List to browse direct entries, clear its filter to see all entries, and check other pages during a scan. Zoom into a folder to browse its contents."
        public static func smallerItems(_ count: String) -> String { "\(count) smaller items" }
        public static let readoutAccessibility = "Storage map details"
        public static let zoomOut = "Zoom Out"
        public static let zoomOutTip = "Show the enclosing folder in the map (⌘↑)"
        public static let zoomOutAccessibility = "Zoom out to the enclosing folder"
        public static let update = "Update Map"
        public static let updateTip =
            "The map holds still while you point at it or have something selected. Click to show what the scan has found since."
        public static let infoAccessibility = "How to read the storage map"
        public static let infoTip = "How to read the map"
        public static let howToRead =
            "Point at a tile for details, and click to select it; the list and inspector follow. Double-click a folder to zoom in, and use Zoom Out or ⌘↑ to go back. Arrow keys move between tiles; Esc clears the selection. Select a file type in the File Types list to highlight its tiles; select it again or press Esc to clear. Hatched blocks are folders that weren’t opened, dotted tiles are groups of small items, and the woven blue group is what macOS manages."
        public static let showList = Menu.showList
        public static let hideList = Menu.hideList
        public static func listToggleTip(_ label: String) -> String { label + " (⌥⌘L)" }
        public static func cardKind(_ kind: String, size: String) -> String { "\(kind) · \(size)" }
        /// A share of the map in the hover card: one format everywhere (see `ShareFormat`).
        public static func cardShare(_ share: Double) -> String { ShareFormat.percent(share) }
        public static func cardShareLine(_ share: String, category: String) -> String {
            share + " of this view · " + category
        }
        public static let cardManaged = "Managed by macOS. Sizes are shown where Spacewise can read them."
        public static let cardProvisional = "Still counting"
        public static let cardPartial = "Partly read, so at least this size"
        public static let menuZoomIn = "Zoom Into Folder"
        public static let waitingTitle = "Drawing the map…"
        public static let waitingDetail = "It appears in a moment and grows as the scan finds more."
        public static let buildingTitle = "Drawing the map…"
        public static let buildingDetail = "Laying out the largest items in this folder."
        public static let nothingSizedTitle = "Nothing sized here yet"
        public static let nothingSizedDetail =
            "Items appear as the scan sizes them. A folder takes up room once something inside it has a size."
        public static let nothingToDrawTitle = "Nothing to draw here"
        public static let nothingToDrawDetail =
            "Nothing in this folder has a size. It may be empty, or it couldn’t be read; a folder that couldn’t be read is unknown, not empty."
    }

    /// Messages shown while the item list is being prepared.
    public enum Waiting {
        public static let title = "Looking for items…"
        public static let detail = "Items appear here as the scan finds them."
        public static let orderingTitle = "Preparing the item list…"
        public static let orderingDetail = "You can keep browsing the map while this folder’s items are ordered."
    }

    /// VoiceOver announcements of the scan lifecycle.
    public enum Announcement {
        public static func scanning(_ scope: String) -> String { "Scanning \(scope)" }
        public static let stopping = "Stopping the scan"
        public static let finished = "Scan finished"
    }

    /// Alerts, the folder picker and the text windows.
    public enum Dialog {
        public static let chooseFolderMessage =
            "Choose a folder on this Mac’s startup drive. Scanning reads filesystem metadata, including names and sizes."
        public static let chooseFolderPrompt = "Scan"
        public static let replaceTitle = "Scan again and replace the current results?"
        public static let replaceDetail =
            "Spacewise replaces the current results once it verifies the new location. Spacewise doesn’t save results."
        public static let replaceCancel = "Cancel"
        public static let replaceConfirm = "Replace Results"
        public static let closeDuringScanTitle = "Stop scanning and close the window?"
        public static let closeDuringScanDetail = "Reopen the window to see what the scan found before it stopped."
        public static let closeDuringScanConfirm = "Stop and Close"
        public static let quitDuringScanTitle = "Stop scanning and quit Spacewise?"
        public static let quitDuringScanDetail = "The scan results will be discarded when Spacewise quits."
        public static let quitDuringScanConfirm = "Stop and Quit"
        public static let keepScanning = "Keep Scanning"
        public static let scanDetailsTitle = "Scan Details"
        public static let recordedPathsTitle = "Locations not read"
        public static let recordedPathsSummary =
            "Where Spacewise couldn’t read or didn’t follow, grouped as in Scan Details. This list stays on this Mac."
        public static let helpSummary = "How to read what Spacewise shows."
    }

    /// Menu bar titles, including the ones that change with state.
    public enum Menu {
        public static let app = "Spacewise"
        public static let about = "About Spacewise"
        public static let services = "Services"
        public static let hide = "Hide Spacewise"
        public static let hideOthers = "Hide Others"
        public static let showAll = "Show All"
        public static let quit = "Quit Spacewise"
        public static let file = "File"
        public static let scanInternal = "Scan Startup Disk"
        public static let rescanInternal = "Rescan Startup Disk…"
        public static let scanFolder = "Scan Folder…"
        public static let rescan = "Rescan"
        public static let stop = "Stop Scan"
        public static let showInFinder = "Show in Finder"
        public static let closeWindow = "Close Window"
        public static let edit = "Edit"
        public static let copy = "Copy"
        public static let view = "View"
        public static let showInspector = "Show Inspector"
        public static let hideInspector = "Hide Inspector"
        public static let showList = "Show Item List"
        public static let hideList = "Hide Item List"
        public static let resetSplit = "Reset Map and List Split"
        public static let scanDetails = "Scan Details…"
        public static let go = "Go"
        public static let enclosingFolder = "Enclosing Folder"
        public static let openFolder = "Open Folder"
        public static let topLevel = "Top Level"
        public static let previousPage = "Previous Page"
        public static let nextPage = "Next Page"
        public static let window = "Window"
        public static let minimize = "Minimize"
        public static let zoom = "Zoom"
        public static let bringAllToFront = "Bring All to Front"
        public static let help = "Help"
    }

    /// Toolbar item labels and tooltips.
    public enum Toolbar {
        public static let up = "Enclosing Folder"
        public static let upTip = "Go to the enclosing folder (⌘↑)"
        public static let scan = "Scan Startup Disk"
        public static let scanTip = "Scan the startup disk (⌘R)"
        public static let folder = "Scan Folder"
        public static let folderTip = "Choose one folder to scan (⇧⌘O)"
        public static let stop = "Stop Scan"
        public static let stopTip = "Stop the active scan (⌘.)"
        public static let scanDetails = "Scan Details"
        public static let scanDetailsTip = "Show what couldn’t be read, and why (⇧⌘D)"
        public static let inspector = "Inspector"
        public static let inspectorTip = "Show or hide the inspector (⌥⌘I)"
    }
}
