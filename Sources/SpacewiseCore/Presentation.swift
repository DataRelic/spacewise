import Foundation

// Pure presentation rules for the native UI. No AppKit, no filesystem access, no node-store copies:
// every value is derived from one bounded ScopeRow/ScopeSummary/ScanProgress.
// Copy follows docs/SCAN-POLICY.md: allocated size is never described as space that can be
// freed, classification/coverage/eligibility stay separate, and no Reserved or capacity-minus-scan figure exists.

/// A size as it should be read: exact, a lower bound, unknown, or not counted in this row.
public struct SizeText: Sendable, Equatable {
    public enum Kind: Sendable { case exact, lowerBound, unknown, notCounted, notApplicable }
    public let kind: Kind
    public let text: String
    public let spoken: String
    public static func make(known: UInt64, partial: Bool, unknownLabel: String = "Unknown") -> SizeText {
        if !partial { return SizeText(kind: .exact, text: SizeFormat.bytes(known), spoken: SizeFormat.spoken(known)) }
        if known == 0 { return SizeText(kind: .unknown, text: unknownLabel, spoken: "unknown") }
        return SizeText(
            kind: .lowerBound, text: "≥ " + SizeFormat.bytes(known), spoken: "at least " + SizeFormat.spoken(known))
    }
}

public enum ResultFreshness: Sendable { case current, stale }
extension ResultFreshness {
    /// Age-based only. This is not filesystem monitoring or sleep/wake invalidation.
    public static let staleAfter: TimeInterval = 3600
    public static func evaluate(age: TimeInterval) -> ResultFreshness { age >= staleAfter ? .stale : .current }
}

public enum PresentationLabels {
    public static func classification(_ value: ContentClassification) -> String {
        switch value {
        case .personal: "Personal"
        case .applicationManaged: "Application-managed"
        case .developerManaged: "Developer-managed"
        case .systemManaged: "System-managed"
        }
    }
    public static func classificationDetail(_ value: ContentClassification) -> String {
        switch value {
        case .personal:
            "Files in your own folders. This label describes ownership, not whether anything is safe to change."
        case .applicationManaged:
            "Managed by an application or installer, such as Application Support, caches or app bundles. Use the owning app to manage it."
        case .developerManaged: "Developer tool or library content, managed by those tools."
        case .systemManaged: "Managed by macOS. Spacewise shows its size where it can read it."
        }
    }
    public static func coverage(_ value: NodeCoverageStatus, reading: Bool = false) -> String {
        switch value {
        case .measured: "Measured"
        case .partial: reading ? "Reading…" : "Partly read"
        case .policyExcluded: "Not followed"
        case .denied: "No access"
        case .unavailable: "Couldn’t be read"
        case .notYetScanned: "Not read yet"
        }
    }
    public static func coverageSymbol(_ value: NodeCoverageStatus) -> String {
        switch value {
        case .measured: "checkmark.circle"
        case .partial: "circle.lefthalf.filled"
        case .policyExcluded: "minus.circle"
        case .denied: "lock"
        case .unavailable: "exclamationmark.triangle"
        case .notYetScanned: "clock"
        }
    }
    public static func coverageDetail(_ value: NodeCoverageStatus) -> String {
        switch value {
        case .measured: "Everything inside was read."
        case .partial: "Some of its contents weren’t read, so its size is at least what is shown."
        case .policyExcluded: "A device or another volume. Spacewise doesn’t follow it, so its contents aren’t counted."
        case .denied: "macOS didn’t allow access. Its contents are unknown, not empty, and aren’t in any total."
        case .unavailable: "Reading failed, or it changed during the scan. Its contents are unknown."
        case .notYetScanned: "This folder hasn’t been opened yet. Its size is unknown."
        }
    }
    public static func operation(_ value: OperationEligibility) -> String {
        switch value {
        case .inspectionOnly: "View only"
        case .explicitSelectionAfterRevalidation: "Move to Trash after confirmation"
        }
    }
    public static func operationDetail(_ value: OperationEligibility) -> String {
        switch value {
        case .inspectionOnly:
            "Spacewise shows this item and never changes it. Its size says nothing about whether it’s safe to remove."
        case .explicitSelectionAfterRevalidation:
            "Confirm its path to move it to the system Trash. Spacewise checks its identity again before moving it."
        }
    }
    public static func issue(_ value: CoverageIssue) -> String {
        switch value {
        case .policyExcluded: "device or other volume, not followed"
        case .denied: "no access"
        case .vanished: "removed during the scan"
        case .metadata: "size couldn’t be read"
        case .enumeration: "folder couldn’t be listed"
        case .volumeBoundary: "other volume, not followed"
        case .placeholder: "stored in the cloud, not downloaded"
        case .invalidRoot: "can’t be scanned"
        case .unmounted: "not mounted"
        case .interruptedVolume: "volume changed during the scan"
        case .unresolvedVolume: "startup storage couldn’t be verified"
        }
    }
    /// A folder selection can be rejected before any root node is added.
    package static func selectedRootRefusal(_ coverage: LocationCoverage) -> String? {
        guard !coverage.wholeDrive else { return nil }
        let reasons = Set(
            coverage.records.compactMap { record -> String? in
                guard record.nodeID == nil, record.reason == .policyExcluded else { return nil }
                switch record.operation {
                case .selectRoot, .resolveRoot, .rootVolume: return record.policyDetail
                default: return nil
                }
            })
        return reasons.count == 1 ? reasons.first : nil
    }
    /// By-design exclusions are not read failures; they are reported separately. The same rule as Scan Details uses.
    public static func isByDesign(_ value: CoverageIssue) -> Bool { value.isExpectedByDesign }
    public static func operationName(_ value: CoverageOperation) -> String {
        switch value {
        case .selectRoot, .resolveRoot, .rootMetadata, .rootVolume: "checking the selection"
        case .placeholder: "checking for cloud placeholder"
        case .identity: "checking identity"
        case .open, .fdopendir: "opening the folder"
        case .readdir: "listing the folder"
        case .fstatat, .metadata: "reading metadata"
        case .traverse: "checking the folder"
        }
    }
}

public struct RowPresentation: Sendable {
    public let id: Int
    public let name: String
    public let kindLabel: String
    public let symbol: String
    public let detail: String
    public let allocated: SizeText
    public let logical: SizeText
    /// Allocated share of the scope's known allocation, when meaningful.
    public let share: Double?
    public let classification: String
    public let coverage: String
    public let coverageSymbol: String
    public let coverageNeedsAttention: Bool
    public let operation: String
    public let canDrill: Bool
    public let isHardLinkAlias: Bool
    public let accessibility: String

    public init(row: ScopeRow, provisional: Bool, scopeAllocated: UInt64) {
        let node = row.node
        let isContainer = node.kind == .directory || node.kind == .package
        let alias = node.hardLinkOwner.map { $0 != node.id } ?? false
        let reading = provisional && isContainer && (row.enumeration == .partial || row.enumeration == .unopened)
        id = node.id
        name = node.name
        isHardLinkAlias = alias
        canDrill = isContainer && node.issue != .policyExcluded && node.issue != .volumeBoundary
        kindLabel =
            switch node.kind {
            case .directory: "Folder"
            case .package: "Package"
            case .file: "File"
            case .symbolicLink: "Symbolic link"
            case .other: "Special item"
            }
        symbol =
            switch (node.issue, node.kind) {
            case (.placeholder?, _): "icloud"
            case (.denied?, _): "lock"
            case (_, .directory): "folder"
            case (_, .package): "shippingbox"
            case (_, .file): "doc"
            case (_, .symbolicLink): "link"
            case (_, .other): "questionmark.square.dashed"
            }
        // Sizes: a symlink is never followed; an alias is counted once at its owner; containers with
        // unknown or unread contents are lower bounds; files with unknown allocation are unknown.
        if node.kind == .symbolicLink {
            allocated = SizeText(kind: .notCounted, text: "Not followed", spoken: "not followed, not counted")
            logical = SizeText(kind: .notApplicable, text: "—", spoken: "not applicable")
        } else if alias {
            allocated = SizeText(kind: .notCounted, text: "At owner", spoken: "counted at its owner")
            logical = allocated
        } else if isContainer {
            let partial = node.allocationUnknown || row.coverage != .measured
            let label = row.coverage == .notYetScanned ? "Not read yet" : "Unknown"
            allocated = .make(known: node.allocatedBytes, partial: partial, unknownLabel: label)
            logical = .make(known: node.logicalBytes, partial: partial, unknownLabel: label)
        } else {
            allocated = .make(known: node.allocatedBytes, partial: node.allocationUnknown)
            // A placeholder's logical size is reported by the filesystem; any other unknown has no size at all.
            let logicalUnknown = node.issue != nil && node.issue != .placeholder
            logical = .make(known: node.logicalBytes, partial: logicalUnknown)
        }
        let countable = !alias && node.kind != .symbolicLink && node.allocatedBytes > 0 && scopeAllocated > 0
        share = countable ? min(1, Double(node.allocatedBytes) / Double(scopeAllocated)) : nil
        classification = PresentationLabels.classification(row.classification)
        coverage = PresentationLabels.coverage(row.coverage, reading: reading)
        coverageSymbol = PresentationLabels.coverageSymbol(row.coverage)
        coverageNeedsAttention = row.coverage == .denied || row.coverage == .unavailable
        operation = PresentationLabels.operation(provisional ? .inspectionOnly : row.eligibility)
        if alias {
            detail = "Hard link · counted at its owner"
        } else if node.kind == .symbolicLink {
            detail = "Symbolic link · not followed"
        } else if let issue = node.issue {
            detail = "\(kindLabel) · \(PresentationLabels.issue(issue))"
        } else if reading {
            detail = "\(kindLabel) · reading…"
        } else if row.coverage == .notYetScanned {
            detail = "\(kindLabel) · not read yet"
        } else {
            detail = kindLabel
        }
        accessibility = [
            "\(node.name), \(kindLabel.lowercased())", "size \(allocated.spoken)", "logical size \(logical.spoken)",
            share.map { ShareFormat.spoken($0) + " of this folder" },
            "managed by \(classification)", coverage.lowercased(), operation.lowercased(),
        ].compactMap { $0 }.joined(separator: ", ")
    }
}

public enum ScanPhase: Sendable, Equatable { case ready, scanning, stopping, settled }
public enum BannerTone: Sendable, Equatable { case neutral, progress, caution }
public enum BannerAction: Sendable, Equatable { case stop, coverageDetails, rescan, privacySettings }
/// What a status line is about. The window shows one at a time; `StatusArea` (SpacewiseAppModel) decides which.
public enum StatusKind: Sendable, Equatable {
    case scanning, stopping, nothingScanned, stopped, stale, couldNotReadAll, complete, movingToTrash
}
/// One status line: a short title, an optional short detail, and its buttons.
public struct Banner: Sendable, Equatable {
    public let kind: StatusKind
    public let tone: BannerTone
    public let symbol: String
    public let title: String
    public let detail: String
    public let actions: [BannerAction]
}

public enum StatusPresentation {
    /// Counts of issue reports by group. A location can be reported more than once.
    public static func issueSummary(_ issues: [CoverageIssue: UInt64]) -> (unreadable: UInt64, byDesign: UInt64) {
        var unreadable: UInt64 = 0
        var byDesign: UInt64 = 0
        for (issue, count) in issues {
            if PresentationLabels.isByDesign(issue) { byDesign += count } else { unreadable += count }
        }
        return (unreadable, byDesign)
    }

    package static func checkingLocation(stopping: Bool) -> Banner {
        Banner(
            kind: stopping ? .stopping : .scanning, tone: .progress, symbol: "magnifyingglass",
            title: stopping ? "Stopping…" : "Checking scan location…", detail: "",
            actions: stopping ? [] : [.stop])
    }

    package static var movingToTrash: Banner {
        Banner(
            kind: .movingToTrash, tone: .progress, symbol: "trash", title: "Moving to Trash…",
            detail: "", actions: [])
    }

    /// The status line for the scan itself, ignoring how old its results are. `offersAccessSettings` adds the
    /// Privacy & Security button to a scan that couldn't read everything.
    public static func outcome(
        phase: ScanPhase, progress: ScanProgress, scopeName: String, coverage: LocationCoverage? = nil,
        offersAccessSettings: Bool = false
    ) -> Banner? {
        switch phase {
        case .ready:
            return nil
        case .scanning:
            let issues = issueSummary(progress.issues)
            var detail =
                "\(SizeFormat.count(progress.entries)) \(Plural.word(progress.entries, "item", "items")) so far"
            if issues.unreadable > 0 { detail += " · \(SizeFormat.count(issues.unreadable)) couldn’t be read" }
            return Banner(
                kind: .scanning, tone: .progress, symbol: "magnifyingglass", title: "Scanning \(scopeName)…",
                detail: detail, actions: [.stop])
        case .stopping:
            return Banner(
                kind: .stopping, tone: .progress, symbol: "stop.circle", title: "Stopping…",
                detail: "Keeping what was found so far.", actions: [])
        case .settled:
            switch progress.state {
            case .completed, .scanning:
                return completion(progress)
            case .limited:
                // Limits that are there by design (protected macOS areas, other volumes) are not a problem with the scan.
                if let coverage, coverage.actionableEvents == 0 { return completion(progress) }
                return Banner(
                    kind: .couldNotReadAll, tone: .caution, symbol: "exclamationmark.triangle",
                    title: progress.issues[.unresolvedVolume, default: 0] > 0
                        ? "Some startup storage couldn’t be verified and isn’t in the totals."
                        : "Some folders couldn’t be read and aren’t in the totals.",
                    detail: "",
                    actions: offersAccessSettings
                        ? [.coverageDetails, .rescan, .privacySettings] : [.coverageDetails, .rescan])
            case .cancelled:
                return Banner(
                    kind: .stopped, tone: .caution, symbol: "stop.circle", title: "Scan stopped",
                    detail: "These results are incomplete.",
                    actions: (coverage?.actionableEvents ?? 0) > 0 ? [.rescan, .coverageDetails] : [.rescan])
            case .invalid:
                let detail = coverage.flatMap(PresentationLabels.selectedRootRefusal).map {
                    "Reason — \($0)"
                }
                return Banner(
                    kind: .nothingScanned, tone: .caution, symbol: "xmark.octagon", title: "Nothing could be scanned",
                    detail: detail ?? "Scan Details shows why.", actions: [.coverageDetails])
            }
        }
    }

    /// The brief confirmation after a scan with nothing wrong.
    static func completion(_ progress: ScanProgress) -> Banner {
        let items = "\(SizeFormat.count(progress.entries)) \(Plural.word(progress.entries, "item", "items"))"
        return Banner(
            kind: .complete, tone: .neutral, symbol: "checkmark.circle", title: "Scan complete",
            detail: "\(items) in \(SizeFormat.duration(progress.elapsedSeconds))", actions: [])
    }

    /// Old results. The window subtitle already says how old, so this only says what it means.
    public static func freshness(_ value: ResultFreshness) -> Banner? {
        guard value == .stale else { return nil }
        return Banner(
            kind: .stale, tone: .caution, symbol: "clock", title: "These results may be out of date.",
            detail: "", actions: [.rescan])
    }

    public static func subtitle(phase: ScanPhase, progress: ScanProgress?, ended: Date?, now: Date = Date()) -> String {
        switch phase {
        case .ready: return "Not scanned yet"
        case .scanning: return "Scanning…"
        case .stopping: return "Stopping…"
        case .settled:
            let label: String
            switch progress?.state {
            case .cancelled: label = "Stopped"
            case .invalid: return "Not scanned"
            default: label = "Scanned"
            }
            guard let ended else { return label }
            return "\(label) \(SizeFormat.age(now.timeIntervalSince(ended))) ago"
        }
    }
}

public struct EmptyScope: Sendable, Equatable {
    public let symbol: String
    public let title: String
    public let detail: String
    public init(symbol: String, title: String, detail: String) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }
    public static func make(
        scopeName: String, enumeration: DirectoryEnumeration?, issue: CoverageIssue?, state: ScanState,
        provisional: Bool
    ) -> EmptyScope {
        if state == .invalid && !provisional {
            return EmptyScope(
                symbol: "xmark.octagon", title: "Nothing was scanned",
                detail: "The selected location couldn’t be scanned. Scan Details shows why. This isn’t an empty result."
            )
        }
        if let issue {
            let access = issue == .denied
            return EmptyScope(
                symbol: access ? "lock" : "exclamationmark.triangle",
                title: access ? "Spacewise can’t read \(scopeName)" : "\(scopeName) couldn’t be fully read",
                detail:
                    "Reason: \(PresentationLabels.issue(issue)). Its contents are unknown, not empty, and aren’t in any total."
            )
        }
        switch enumeration {
        case .enumerated:
            return EmptyScope(
                symbol: "folder", title: "\(scopeName) is empty",
                detail: "No items were found, including hidden files.")
        case .unopened, .partial:
            if provisional {
                return EmptyScope(
                    symbol: "clock", title: "Reading \(scopeName)…",
                    detail: "Items appear here as the scan discovers them.")
            }
            return EmptyScope(
                symbol: "stop.circle", title: "Nothing found before the scan stopped",
                detail: "\(scopeName) wasn’t read to the end, so its contents are unknown, not empty.")
        case .cancelled:
            return EmptyScope(
                symbol: "stop.circle", title: "Nothing found before the scan stopped",
                detail: "\(scopeName) was being read when the scan stopped, so its contents are unknown, not empty.")
        case .openFailed, .skipped, .listingFailed:
            // These always carry an issue, which is reported above; this is only a fallback with the same meaning.
            return EmptyScope(
                symbol: "exclamationmark.triangle", title: "\(scopeName) couldn’t be fully read",
                detail: "Its contents are unknown, not empty, and aren’t in any total.")
        case nil:
            return EmptyScope(
                symbol: "tray", title: "No items to show",
                detail: provisional
                    ? "Items appear as the scan discovers them." : "The scan found nothing at this level.")
        }
    }
}

/// Scope header texts. While scanning, totals are what was found so far; once settled they are final.
public struct ScopeHeaderPresentation: Sendable {
    public let allocated: SizeText
    public let logical: SizeText
    /// The number of direct entries before filtering, including entries beyond the current live page.
    public let itemsText: String
    public init(summary: ScopeSummary, provisional: Bool, total: Int) {
        allocated = .make(known: summary.allocatedBytes, partial: summary.allocationUnknown || provisional)
        logical = .make(known: summary.logicalBytes, partial: summary.allocationUnknown || provisional)
        itemsText = SizeFormat.count(UInt64(total))
    }
}

/// The startup disk's capacity as the file system reports it, for the Ready screen. There is deliberately no
/// remainder, Reserved or reclaimable figure, and it is never compared with scan totals.
///
/// Available space is the figure Finder shows: what can be used for something the person asks for, which includes
/// purgeable space macOS releases on demand. The plain free-space figure leaves that out and makes the disk look
/// fuller than Finder says; it is used only when the first is missing.
public struct DiskCapacity: Sendable, Equatable {
    public let total: UInt64
    public let available: UInt64
    public var used: UInt64 { total - available }
    /// Used space as a share of the total, 0...1.
    public var usedFraction: Double { Double(used) / Double(total) }

    /// Nil when the total or both available figures are missing, or the total is zero.
    public init?(_ context: VolumeContext?) {
        guard let capacity = context?.capacity, capacity > 0,
            let free = context?.availableForImportantUsage ?? context?.available
        else { return nil }
        total = UInt64(capacity)
        available = min(UInt64(max(0, free)), total)
    }

    /// The three figures in one unit and one precision, rounded so that used and available add up to the total as
    /// shown. The unit and precision follow the smaller of used and available, so neither rounds away.
    private var shown: (used: String, available: String, total: String, unit: String) {
        let smaller = min(used, available)
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB", "EB"]
        var power = 0
        var scale: UInt64 = 1
        // A full or empty disk has a zero figure; the total then sets the unit.
        let reference = smaller >= 1000 ? smaller : total
        while power < units.count - 1, reference / scale >= 1000 {
            scale *= 1000
            power += 1
        }
        let decimals = power > 0 && Double(reference) / Double(scale) < 100 ? 1 : 0
        let step = Double(scale) / (decimals == 1 ? 10 : 1)
        let totalSteps = (Double(total) / step).rounded()
        let availableSteps = (Double(available) / step).rounded()
        // Grouped thousands, so a 2 TB disk shown in GB reads "1,249 GB" rather than "1249 GB".
        let style = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(decimals))
            .locale(Locale(identifier: "en_US"))
        func text(_ steps: Double) -> String {
            (steps * step / Double(scale)).formatted(style)
        }
        return (text(totalSteps - availableSteps), text(availableSteps), text(totalSteps), units[power])
    }

    public var caption: String {
        let figures = shown
        return "\(figures.used) \(figures.unit) used · \(figures.available) \(figures.unit) available · "
            + "\(figures.total) \(figures.unit) total"
    }
    public var spoken: String {
        let figures = shown
        let unit =
            [
                "KB": "kilobytes", "MB": "megabytes", "GB": "gigabytes", "TB": "terabytes", "PB": "petabytes",
                "EB": "exabytes",
            ][figures.unit] ?? figures.unit
        return "\(figures.used) \(unit) used, \(figures.available) \(unit) available, of \(figures.total) \(unit)"
    }
    public static let unavailable = "The startup disk’s capacity isn’t available."
}

public struct InspectorField: Sendable, Equatable {
    /// What a field is, so code can find or treat one without matching its label text.
    public enum Role: Sendable, Equatable {
        /// A short fact or an explanation.
        case detail
        /// Where the item is (its path), or what stands in for that.
        case location
        /// Further paths, such as the physical locations behind a merged folder.
        case paths
    }
    public let label: String
    public let value: String
    public let role: Role
    public init(label: String, value: String, role: Role = .detail) {
        self.label = label
        self.value = value
        self.role = role
    }
}

public enum InspectorPresentation {
    /// Fields for one selected row. `path` is nil while scanning (rows carry no path) and stays local.
    public static func fields(
        for row: ScopeRow, presentation: RowPresentation, provisional: Bool, path: String?,
        ownerName: String?, records: [CoverageRecord]
    ) -> [InspectorField] {
        var fields = [
            InspectorField(label: "Name", value: row.node.name),
            InspectorField(label: "Kind", value: presentation.kindLabel),
        ]
        fields.append(
            InspectorField(
                label: ProductCopy.InspectorFields.location, value: path ?? "Shown when the scan finishes",
                role: .location))
        fields.append(
            InspectorField(label: "Allocated", value: detail(presentation.allocated, exact: row.node.allocatedBytes)))
        var logicalValue = detail(presentation.logical, exact: row.node.logicalBytes)
        if presentation.allocated.kind == .exact, presentation.logical.kind == .exact,
            row.node.logicalBytes != row.node.allocatedBytes
        {
            logicalValue +=
                row.node.logicalBytes > row.node.allocatedBytes
                ? ". Larger than allocated: a sparse, compressed or cloned file."
                : ". Smaller than allocated: disk space is used in whole blocks."
        }
        fields.append(InspectorField(label: "Logical", value: logicalValue))
        fields.append(
            InspectorField(
                label: "Classification",
                value: "\(presentation.classification). \(PresentationLabels.classificationDetail(row.classification))")
        )
        var coverage = "\(presentation.coverage). \(PresentationLabels.coverageDetail(row.coverage))"
        if let issue = row.node.issue { coverage += " Reason: \(PresentationLabels.issue(issue))." }
        for record in records.prefix(3) {
            coverage +=
                " Observed \(PresentationLabels.issue(record.reason)) while \(PresentationLabels.operationName(record.operation))\(record.count > 1 ? " (\(record.count) times)" : "")."
        }
        fields.append(InspectorField(label: "Coverage", value: coverage))
        fields.append(
            InspectorField(
                label: "Operations",
                value:
                    "\(presentation.operation). \(PresentationLabels.operationDetail(provisional ? .inspectionOnly : row.eligibility))"
            ))
        if presentation.isHardLinkAlias {
            fields.append(
                InspectorField(
                    label: "Hard link",
                    value: ownerName.map { "Its bytes are counted once, at “\($0)”." }
                        ?? "Its bytes are counted once, at another path."))
        }
        if provisional {
            fields.append(
                InspectorField(label: "Status", value: "Still counting. Sizes can grow until the scan finishes."))
        }
        return fields
    }
    private static func detail(_ size: SizeText, exact: UInt64) -> String {
        switch size.kind {
        case .exact: return "\(size.text) (\(SizeFormat.exact(exact)))"
        case .lowerBound: return "At least \(SizeFormat.bytes(exact)); some contents weren’t read"
        default: return size.text
        }
    }
}

/// Fixed explanatory copy, kept in one place so tests can check it never implies unsupported claims.
public enum ProductCopy {
    public static let helpTitle = "Spacewise Help"
    public static let helpBody = """
        Spacewise shows what takes up space on your disk. Scans read names, sizes and filesystem metadata without reading file contents or requesting cloud downloads. Open and Quick Look can let macOS or another app read the item you choose. See Help > \(privacyPolicyTitle) for details and how to report a problem.

        After a scan, Move to Trash is available for eligible personal files in your home folder. Confirm the file’s path and Spacewise checks the file again before moving it to the system Trash, then rescans the same scope. Use Finder to restore a trashed file. You can still browse folders and show them in Finder.

        Scan Startup Disk covers everything on the startup disk that you can read: your home folder (hidden folders too), applications, and shared system locations. Scan Folder covers one folder you choose on the startup drive.

        macOS may ask before Spacewise opens some folders, such as Desktop, Documents and Downloads. If you don’t allow it, those folders are marked as not read and the rest of the scan carries on. Full Disk Access, in System Settings > Privacy & Security, lets Spacewise read more of the disk. You control Full Disk Access. If you change access in System Settings, run the scan again.

        Size is the space a file takes up on disk. Logical size is the length a file reports; sparse, compressed and cloned files make the two differ. Neither is a promise of space you could free.

        Hard links are counted once. Symbolic links, other volumes and devices aren’t followed.

        A folder that couldn’t be read is unknown, not empty, and isn’t in any total. A size marked ≥ is at least that much. Scan Details lists what couldn’t be read and why.

        “Managed by” says who looks after an item: you, an app, developer tools or macOS. It isn’t advice about what is safe to remove.

        The disk’s capacity and available space come from macOS and won’t match a scan’s total: snapshots, space APFS volumes share, and folders that couldn’t be read make up the difference.

        Results show the disk as it was during the scan. Rescan to refresh them.
        """
}
