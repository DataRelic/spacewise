import Foundation

/// "Scan Details": what the scan couldn't read, in plain reason groups, with expected limits kept apart from anything
/// that needs attention. Counts are reports (a location can be reported more than once), never unique locations. Raw
/// paths are a further disclosure grouped the same way. Pure; reads only the aggregate counters and the bounded records.
public struct ScanDetailLine: Sendable, Equatable {
    public let title: String
    public let count: UInt64
    public let explanation: String
}
public struct ScanDetailGroup: Sendable, Equatable {
    public let title: String
    public let expected: Bool
    public let lines: [ScanDetailLine]
}
public struct ScanDetails: Sendable, Equatable {
    public let groups: [ScanDetailGroup]
    public let truncated: Bool
    public let totalEvents: UInt64
    /// Denials outside the areas macOS always protects: the case where Full Disk Access can help.
    public let deniedNeedingAttention: UInt64
    private let selectedRootRefusal: String?

    public var needsAttention: Bool { groups.contains { !$0.expected } }
    /// What every scan's sizes mean. It is said once, here, rather than on every completed scan.
    public static let sizesNote =
        "Sizes are what files take up on disk. They don’t account for everything macOS reports as used, and they aren’t necessarily space you could free."

    package static let accessRecovery =
        "Open System Settings → Privacy & Security → Full Disk Access. If you choose to allow access, enable Spacewise. If macOS asks you to quit and reopen Spacewise, do that first."

    package static let rescanAfterAccess =
        "After changing access, use Rescan if these results are still on screen. Otherwise, start the same scan again. The totals update after a new scan."

    /// Plain text for the details panel: groups first, no paths, then what the sizes mean.
    public var text: String {
        guard !groups.isEmpty else { return "Nothing was left unread.\n\n" + Self.sizesNote }
        var out: [String] = []
        if let selectedRootRefusal {
            out += ["Spacewise couldn’t scan a selected location (\(selectedRootRefusal)).", ""]
        }
        for group in groups {
            out.append(group.title.uppercased())
            for line in group.lines {
                out.append("• \(line.title): \(SizeFormat.count(line.count)) — \(line.explanation)")
            }
            out.append("")
        }
        out.append(
            "A location can be counted more than once. Unread areas remain unknown, not empty, and aren’t in any total."
        )
        if truncated { out.append("Only some locations were kept, but the counts above include everything.") }
        out.append("")
        if needsAttention {
            out += ["TRY AGAIN"]
            if deniedNeedingAttention > 0 {
                out += [Self.accessRecovery, "", Self.rescanAfterAccess, ""]
            } else {
                out += [
                    "Once the location is available and readable, run the same scan again to refresh the totals.", "",
                ]
            }
        }
        out.append(Self.sizesNote)
        return out.joined(separator: "\n")
    }

    public static func make(_ coverage: LocationCoverage) -> ScanDetails {
        let counts = coverage.reasonCounts
        func count(_ issues: CoverageIssue...) -> UInt64 { issues.reduce(0) { $0 + counts[$1, default: 0] } }
        // Severity is fixed for every reason except denial, so the actionable denials are what the aggregate leaves over.
        let otherActionable = counts.filter { !$0.key.isExpectedByDesign && $0.key != .denied }.values.reduce(0, +)
        let actionableDenials =
            coverage.actionableEvents > otherActionable ? coverage.actionableEvents - otherActionable : 0
        let deniedActionable = min(count(.denied), actionableDenials)
        let deniedExpected = count(.denied) - deniedActionable

        var expected: [ScanDetailLine] = []
        func add(_ lines: inout [ScanDetailLine], _ title: String, _ value: UInt64, _ why: String) {
            if value > 0 { lines.append(ScanDetailLine(title: title, count: value, explanation: why)) }
        }
        add(
            &expected, "Protected macOS areas", deniedExpected,
            "macOS keeps these closed to apps. What could be read is counted; the rest is unknown.")
        add(
            &expected, "Not followed", count(.policyExcluded, .volumeBoundary),
            "devices, other volumes and links, so nothing is counted twice.")
        add(
            &expected, "Cloud placeholders", count(.placeholder),
            "items stored in the cloud aren’t downloaded to size them.")
        add(
            &expected, "Storage not mounted", count(.unmounted),
            "volumes that aren’t mounted, such as recovery. Their size is unknown and isn’t in any total.")

        var attention: [ScanDetailLine] = []
        add(
            &attention, "Startup storage couldn’t be verified", count(.unresolvedVolume),
            "Spacewise couldn’t confirm which storage belongs to the startup disk. Unverified volumes were left out.")
        add(
            &attention, "Access denied", deniedActionable,
            "a location you chose, or one macOS doesn’t normally protect, couldn’t be opened. Full Disk Access may help."
        )
        add(
            &attention, "Couldn’t be read", count(.metadata, .enumeration),
            "reading failed, so the contents are unknown.")
        add(
            &attention, "Changed during the scan", count(.vanished, .interruptedVolume),
            "items or a volume changed while scanning, so some sizes may be out of date.")
        add(&attention, "Can’t be scanned", count(.invalidRoot), "the chosen location couldn’t be scanned.")

        var groups: [ScanDetailGroup] = []
        if !attention.isEmpty {
            groups.append(ScanDetailGroup(title: "Needs attention", expected: false, lines: attention))
        }
        if !expected.isEmpty {
            groups.append(ScanDetailGroup(title: "Expected limits", expected: true, lines: expected))
        }
        return ScanDetails(
            groups: groups, truncated: coverage.truncated, totalEvents: coverage.events,
            deniedNeedingAttention: deniedActionable,
            selectedRootRefusal: PresentationLabels.selectedRootRefusal(coverage))
    }

    /// The further disclosure: retained locations under the same group headings. Bounded by the local record limit.
    public static func paths(_ coverage: LocationCoverage) -> String {
        var needs: [String] = []
        var expectedLines: [String] = []
        for record in coverage.records {
            var label = PresentationLabels.issue(record.reason)
            if record.reason == .policyExcluded, let detail = record.policyDetail {
                label = "not followed (\(detail))"
            } else if record.reason == .unresolvedVolume, let detail = record.policyDetail {
                label = detail
            }
            let line =
                "\(label) · \(record.path)"
                + (record.count > 1 ? "  ×\(record.count)" : "")
            if record.severity(wholeDrive: coverage.wholeDrive) == .actionable {
                needs.append(line)
            } else {
                expectedLines.append(line)
            }
        }
        var out: [String] = []
        if !needs.isEmpty { out += ["NEEDS ATTENTION"] + needs + [""] }
        if !expectedLines.isEmpty { out += ["EXPECTED LIMITS"] + expectedLines + [""] }
        if coverage.truncated {
            out.append("Only the first \(coverage.limit) locations are kept; the counts in Scan Details are complete.")
        }
        return out.isEmpty ? "No locations were recorded." : out.joined(separator: "\n")
    }
}
