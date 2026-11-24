import SpacewiseCore

/// What Open does for one selected item.
public enum OpenBehavior: Sendable, Equatable {
    /// Open it with its default app (a folder opens in Finder).
    case open
    /// Opening it could start something the person did not expect, so only Show in Finder is offered.
    case showInFinderOnly
    /// The item has no location to act on.
    case unavailable
}

/// The facts the Open and Quick Look rules read about one item.
public struct ItemFacts: Sendable, Equatable {
    public var kind: NodeKind
    public var classification: ContentClassification
    public var issue: CoverageIssue?
    /// The item has a path on disk (settled results only; a summed group or the managed group has none).
    public var hasLocation: Bool
    /// A plain file with an execute bit: opening it from Finder would run it in Terminal.
    public var isExecutableFile: Bool

    public init(
        kind: NodeKind, classification: ContentClassification, issue: CoverageIssue?, hasLocation: Bool,
        isExecutableFile: Bool = false
    ) {
        self.kind = kind
        self.classification = classification
        self.issue = issue
        self.hasLocation = hasLocation
        self.isExecutableFile = isExecutableFile
    }
}

/// Spacewise only reads. Open and Quick Look are reading actions, but Open hands the item to another program, so it is
/// held back wherever that could do more than show the item:
/// - system-managed items (macOS content: opening could launch a system tool or helper),
/// - executable plain files (Finder runs them in Terminal),
/// - symbolic links and special items (the app never follows links; devices and sockets have nothing to show),
/// - cloud placeholders (opening downloads the file, which Spacewise promises not to do),
/// - items that could not be read (denied, vanished, failed): their state is unknown.
/// Those items still offer Show in Finder. Everything else (documents, folders, packages and apps the person
/// installed) opens as a double-click in Finder would.
public enum ItemOpenRule {
    public static func open(_ item: ItemFacts) -> OpenBehavior {
        guard item.hasLocation else { return .unavailable }
        if item.kind == .symbolicLink || item.kind == .other { return .showInFinderOnly }
        if item.issue != nil { return .showInFinderOnly }
        if item.classification == .systemManaged { return .showInFinderOnly }
        if item.kind == .file && item.isExecutableFile { return .showInFinderOnly }
        return .open
    }

    /// Quick Look only previews, so it is offered more widely than Open, but never for links (not followed) or
    /// placeholders (a preview could download the file), or items that were not read.
    public static func canQuickLook(_ item: ItemFacts) -> Bool {
        guard item.hasLocation else { return false }
        if item.kind == .symbolicLink || item.kind == .other { return false }
        return item.issue == nil
    }
}
