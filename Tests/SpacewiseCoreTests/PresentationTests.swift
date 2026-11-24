import Foundation
import SpacewiseFixtures
import Testing

@testable import SpacewiseCore

private func settledRow(_ fixture: PresentationFixture, named name: String, parent: Int? = 0) -> ScopeRow? {
    fixture.result.childIDs(of: parent).lazy.compactMap { fixture.result.scopeRow(for: $0) }.first {
        $0.node.name == name
    }
}
private func present(_ row: ScopeRow, in fixture: PresentationFixture) -> RowPresentation {
    RowPresentation(row: row, provisional: false, scopeAllocated: fixture.result.nodes[0].allocatedBytes)
}

@Test func decimalSizesRoundWithoutOverflowingUnits() {
    #expect(SizeFormat.bytes(0) == "0 bytes")
    #expect(SizeFormat.bytes(1) == "1 byte")
    #expect(SizeFormat.bytes(999) == "999 bytes")
    #expect(SizeFormat.bytes(1000) == "1.0 KB")
    #expect(SizeFormat.bytes(4096) == "4.1 KB")
    #expect(SizeFormat.bytes(999_950) == "1.0 MB")
    #expect(SizeFormat.bytes(12_400_000_000) == "12.4 GB")
    #expect(SizeFormat.bytes(123_456_000_000) == "123 GB")
    #expect(SizeFormat.bytes(UInt64.max).hasSuffix("EB"))
    #expect(SizeFormat.spoken(2_000_000) == "2.0 megabytes")
}

@Test func exactByteCountsUseTheSingularForOneByte() {
    #expect(SizeFormat.exact(0) == "0 bytes")
    #expect(SizeFormat.exact(1) == "1 byte")
    #expect(SizeFormat.exact(2) == "2 bytes")
}

/// The number of decimals is chosen from the rounded value, so a size that rounds up to 100 loses its decimal
/// just like an exact 100 does, and a size that rounds up to 1000 moves to the next unit.
@Test func sizeRoundingIsConsistentAcrossEachUnitBoundary() {
    let units = ["KB", "MB", "GB", "TB", "PB"]
    var unitBytes: UInt64 = 1
    for (position, unit) in units.enumerated() {
        unitBytes *= 1000
        let thousandth = unitBytes / 1000  // one thousandth of the unit
        #expect(SizeFormat.bytes(99_949 * thousandth) == "99.9 \(unit)", "just below 99.95 \(unit)")
        #expect(SizeFormat.bytes(99_960 * thousandth) == "100 \(unit)", "rounds up to 100 \(unit)")
        #expect(SizeFormat.bytes(100_000 * thousandth) == "100 \(unit)", "exactly 100 \(unit)")
        #expect(SizeFormat.bytes(100_400 * thousandth) == "100 \(unit)", "just above 100 \(unit)")
        #expect(SizeFormat.bytes(999_499 * thousandth) == "999 \(unit)", "just below 999.5 \(unit)")
        if position + 1 < units.count {
            #expect(
                SizeFormat.bytes(999_500 * thousandth) == "1.0 \(units[position + 1])", "rounds up into the next unit")
        }
    }
    #expect(SizeFormat.bytes(9_996 * 1_000_000_000_000_000) == "10.0 EB")
    #expect(
        SizeFormat.bytes(99_949) == "99.9 KB" && SizeFormat.bytes(99_960) == "100 KB"
            && SizeFormat.bytes(100_000) == "100 KB")
}

@Test func unknownPartialAndExactSizesAreNeverConfused() {
    #expect(SizeText.make(known: 0, partial: true).kind == .unknown)
    #expect(SizeText.make(known: 0, partial: true).text == "Unknown")
    let bound = SizeText.make(known: 5000, partial: true)
    #expect(bound.kind == .lowerBound && bound.text == "≥ 5.0 KB" && bound.spoken.hasPrefix("at least"))
    let exactZero = SizeText.make(known: 0, partial: false)
    #expect(exactZero.kind == .exact && exactZero.text == "0 bytes")
}

@Test func rowsKeepClassificationCoverageAndOperationsSeparate() {
    let fixture = PresentationFixtures.scenario(.limited)
    let denied = present(settledRow(fixture, named: "Denied")!, in: fixture)
    #expect(denied.coverage == "No access" && denied.coverageNeedsAttention)
    #expect(denied.classification == "Personal")  // ownership label says nothing about coverage
    #expect(denied.operation == "View only")
    #expect(denied.allocated.kind == .unknown && denied.logical.kind == .unknown)
    #expect(denied.share == nil)

    let library = present(settledRow(fixture, named: "Library")!, in: fixture)
    #expect(library.classification == "Application-managed")
    #expect(library.operation == "View only")

    let placeholder = present(settledRow(fixture, named: "Placeholder")!, in: fixture)
    #expect(placeholder.allocated.kind == .unknown)  // allocation unknown, never zero
    #expect(placeholder.logical.kind == .exact && placeholder.logical.text == "500 KB")
    #expect(placeholder.detail.contains("stored in the cloud"))

    let excluded = present(settledRow(fixture, named: "Excluded mount")!, in: fixture)
    #expect(excluded.coverage == "Not followed" && !excluded.canDrill)

    let personalFile = present(settledRow(fixture, named: "Archive")!, in: fixture)
    #expect(personalFile.coverage == "Measured")
    #expect(personalFile.operation == "View only")  // eligibility is its own dimension

    let sparse = present(settledRow(fixture, named: "Sparse image")!, in: fixture)
    #expect(sparse.logical.text == "1.1 GB" && sparse.allocated.text == "8.2 KB")

    let alias = present(settledRow(fixture, named: "Archive link")!, in: fixture)
    #expect(alias.isHardLinkAlias && alias.allocated.kind == .notCounted && alias.share == nil)

    // A very long name is kept whole in the model (shortening is the view's job) and still reads as a plain file.
    let longName = String(repeating: "long-name-", count: 20)
    let long = present(settledRow(fixture, named: longName)!, in: fixture)
    #expect(long.name == longName && long.accessibility.contains(longName))
    #expect(long.kindLabel == "File" && !long.canDrill)
    #expect(long.logical.text == "17 bytes" && long.allocated.text == "4.1 KB")
}

@Test func provisionalRowsAreLowerBoundsAndInspectionOnly() {
    let fixture = PresentationFixtures.scenario(.scanning)
    #expect(fixture.snapshot.provisional)
    let rows = fixture.snapshot.rows.map {
        RowPresentation(row: $0, provisional: true, scopeAllocated: fixture.snapshot.scope.allocatedBytes)
    }
    #expect(rows.allSatisfy { $0.operation == "View only" })
    // A folder whose own listing finished can still hold unfinished descendants: partial, not "reading".
    let finished = rows.first { $0.name == "Library" }!
    #expect(finished.coverage == "Partly read" && finished.allocated.kind != .exact)
    let deep = rows.first { $0.name == "Deep" }!
    #expect(
        deep.coverage == "Reading…" && deep.detail.contains("reading") && deep.allocated.kind != .exact && deep.canDrill
    )
}

@Test func settledRowsMatchTheProgressivePathForTheSameScope() {
    let fixture = PresentationFixtures.scenario(.complete)
    let settled = fixture.result.childIDs(of: 0).prefix(ScopeSnapshot.pageSize).compactMap {
        fixture.result.scopeRow(for: $0)
    }
    #expect(settled.count == ScopeSnapshot.pageSize)
    // Same classification and coverage rule for every shared node.
    for row in fixture.snapshot.rows {
        let match = fixture.result.scopeRow(for: row.node.id)!
        #expect(match.classification == row.classification)
        #expect(match.coverage == row.coverage)
    }
    #expect(fixture.result.scopeRow(for: -1) == nil && fixture.result.scopeRow(for: .max) == nil)
}

@Test func scopeSummariesCarryBreadcrumbsAndAuthoritativeTotals() {
    let fixture = PresentationFixtures.scenario(.complete)
    let result = fixture.result
    let deep = result.nodes.firstIndex { $0.name == "Deep" }!
    let leaf = result.nodes.indices.last { result.nodes[$0].name == "Nested" }!
    let summary = result.scopeSummary(parent: leaf)
    #expect(summary.crumbs.first?.id == 0 && summary.crumbs.last?.id == leaf)
    #expect(summary.crumbs.count == 34)  // root, Deep and 32 nested levels
    #expect(summary.parentOfScope == summary.crumbs[32].id)
    #expect(result.scopeSummary(parent: deep).crumbs.map(\.name) == ["Example", "Deep"])
    let top = result.scopeSummary(parent: nil)
    #expect(top.crumbs.isEmpty && top.allocatedBytes == result.nodes[0].allocatedBytes)
    #expect(result.scopeSummary(parent: 0).allocationUnknown == false)
    #expect(PresentationFixtures.scenario(.cancelled).result.scopeSummary(parent: 0).allocationUnknown)
}

@Test func scanningSnapshotsExposeProvisionalScopeTotalsAndEnumeration() {
    let fixture = PresentationFixtures.scenario(.scanning)
    let scope = fixture.snapshot.scope
    #expect(scope.allocationUnknown)
    #expect(scope.crumbs.map(\.name) == ["Example"])
    #expect(scope.allocatedBytes > 0)
    let header = ScopeHeaderPresentation(
        summary: scope, provisional: true, total: fixture.snapshot.discoveredChildren)
    #expect(header.allocated.kind == .lowerBound)
    #expect(header.itemsText == SizeFormat.count(UInt64(fixture.snapshot.discoveredChildren)))
    let settled = ScopeHeaderPresentation(
        summary: PresentationFixtures.scenario(.complete).result.scopeSummary(parent: 0),
        provisional: false, total: 300)
    #expect(settled.allocated.kind == .exact && settled.itemsText == "300")
}

@Test func bannersDescribeEachOutcomeAndFreshnessIndependently() {
    func banner(_ scenario: PresentationScenario, phase: ScanPhase = .settled) -> Banner? {
        StatusPresentation.outcome(
            phase: phase, progress: PresentationFixtures.scenario(scenario).result.progress, scopeName: "Example")
    }
    #expect(StatusPresentation.outcome(phase: .ready, progress: ScanProgress(), scopeName: "x") == nil)
    let complete = banner(.complete)!
    #expect(
        complete.kind == .complete && complete.tone == .neutral && complete.title == "Scan complete"
            && complete.actions.isEmpty)
    let limited = banner(.limited)!
    #expect(
        limited.kind == .couldNotReadAll && limited.tone == .caution && limited.actions == [.coverageDetails, .rescan])
    #expect(limited.title == "Some folders couldn’t be read and aren’t in the totals.")
    let cancelled = banner(.cancelled)!
    #expect(
        cancelled.title == "Scan stopped" && cancelled.detail.contains("incomplete") && cancelled.actions == [.rescan])
    let scanning = banner(.scanning, phase: .scanning)!
    #expect(scanning.tone == .progress && scanning.actions == [.stop] && scanning.detail.hasSuffix("so far"))
    let stopping = banner(.scanning, phase: .stopping)!
    #expect(stopping.actions.isEmpty && stopping.title == "Stopping…")
    var invalid = ScanProgress()
    invalid.state = .invalid
    #expect(
        StatusPresentation.outcome(phase: .settled, progress: invalid, scopeName: "x")?.title
            == "Nothing could be scanned")

    // A stale complete scan stays "complete"; staleness is a separate banner.
    let stale = PresentationFixtures.scenario(.stale)
    #expect(banner(.stale)?.title == "Scan complete")
    let freshness = StatusPresentation.freshness(stale.freshness)!
    #expect(freshness.kind == .stale && freshness.actions == [.rescan])
    #expect(StatusPresentation.freshness(.current) == nil)
    #expect(ResultFreshness.evaluate(age: 3599) == .current && ResultFreshness.evaluate(age: 3600) == .stale)
}

@Test func issueSummarySeparatesUnreadableFromByDesign() {
    let summary = StatusPresentation.issueSummary([
        .denied: 3, .vanished: 1, .policyExcluded: 2, .volumeBoundary: 4, .placeholder: 5,
        .unmounted: 6,
    ])
    #expect(summary.unreadable == 4 && summary.byDesign == 17)
    // The same rule as Scan Details: unmounted storage is an expected limit, not something that couldn't be read.
    for issue in CoverageIssue.allCases { #expect(PresentationLabels.isByDesign(issue) == issue.isExpectedByDesign) }
}

@Test(arguments: [
    "network or non-local volume", "removable volume", "could not verify this volume is on the startup drive",
])
func selectedVolumeRefusalSurfacesTheRecordedReason(reason: String) {
    let path = "/Volumes/Chosen"
    var coverage = LocationCoverage()
    coverage.record(
        path: path, nodeID: nil, operation: .rootVolume, reason: .policyExcluded, policyDetail: reason)
    var progress = ScanProgress()
    progress.state = .invalid

    let banner = StatusPresentation.outcome(
        phase: .settled, progress: progress, scopeName: "Chosen", coverage: coverage)
    #expect(banner?.kind == .nothingScanned)
    #expect(banner?.detail.contains(reason) == true)
    #expect(banner?.actions == [.coverageDetails])

    let details = ScanDetails.make(coverage)
    #expect(details.text.contains(reason))
    #expect(details.text.contains(path) == false)
    #expect(ScanDetails.paths(coverage).contains("not followed (\(reason)) · \(path)"))
}

@Test func traversalExclusionDoesNotBecomeTheSelectedRootRefusal() {
    var coverage = LocationCoverage()
    coverage.record(
        path: "/Chosen/dev", nodeID: 1, operation: .traverse, reason: .policyExcluded,
        policyDetail: "device filesystem")
    var progress = ScanProgress()
    progress.state = .invalid

    let banner = StatusPresentation.outcome(
        phase: .settled, progress: progress, scopeName: "Chosen", coverage: coverage)
    #expect(banner?.detail == "Scan Details shows why.")
    #expect(ScanDetails.make(coverage).text.contains("Spacewise couldn’t scan a selected location") == false)
    #expect(ScanDetails.paths(coverage).contains("not followed (device filesystem) · /Chosen/dev"))
}

@Test func emptyScopesExplainWhyTheyAreEmpty() {
    func make(
        _ enumeration: DirectoryEnumeration?, issue: CoverageIssue? = nil, state: ScanState = .completed,
        provisional: Bool = false
    ) -> EmptyScope {
        EmptyScope.make(
            scopeName: "Folder", enumeration: enumeration, issue: issue, state: state, provisional: provisional)
    }
    #expect(make(.enumerated).title == "Folder is empty")
    #expect(make(.enumerated, issue: .denied).title == "Spacewise can’t read Folder")
    #expect(make(.enumerated, issue: .denied).detail.contains("unknown, not empty"))
    #expect(make(.partial, state: .scanning, provisional: true).title == "Reading Folder…")
    #expect(make(.cancelled, state: .cancelled).title == "Nothing found before the scan stopped")
    #expect(make(.unopened, state: .cancelled).detail.contains("not empty"))
    #expect(make(nil, state: .invalid).title == "Nothing was scanned")
    let empty = PresentationFixtures.scenario(.empty)
    let summary = empty.result.scopeSummary(parent: 0)
    #expect(make(summary.enumeration, issue: summary.issue).title == "Folder is empty")
    #expect(empty.snapshot.rows.isEmpty && empty.snapshot.scope.enumeration == .enumerated)
}

@Test func pagingTextReportsCountsWithinThePage() {
    let summary = PresentationFixtures.scenario(.scanning).snapshot.scope
    let header = ScopeHeaderPresentation(summary: summary, provisional: true, total: 600)
    #expect(header.itemsText == "600")
    #expect(ProductCopy.List.livePage(2, entries: 256, matches: 3) == "Scan page 2 · 3 of 256 entries match")
    #expect(ProductCopy.List.livePage(2, entries: 256, matches: 0) == "Scan page 2 · 0 of 256 entries match")
    #expect(ProductCopy.List.livePage(2, entries: 256, matches: nil) == "Scan page 2 · 256 entries on this page")
    #expect(ProductCopy.List.livePage(2, entries: nil, matches: nil) == "Scan page 2 · Loading entries…")
}

@Test func diskCapacityShowsUsedAvailableAndTotalOnly() {
    var context = VolumeContext(root: URL(fileURLWithPath: "/"), scope: "test")
    context.capacity = 500_000_000_000
    context.available = 120_000_000_000
    context.availableForImportantUsage = nil
    let capacity = try! #require(DiskCapacity(context))
    #expect(capacity.used == 380_000_000_000 && abs(capacity.usedFraction - 0.76) < 0.0001)
    #expect(capacity.caption == "380 GB used · 120 GB available · 500 GB total")
    #expect(DiskCapacity(nil) == nil)
    context.available = nil
    #expect(DiskCapacity(context) == nil)  // never a guessed figure
    context.available = 900_000_000_000
    context.capacity = 500_000_000_000
    #expect(DiskCapacity(context)?.used == 0)  // available can't exceed the total
    context.capacity = 0
    #expect(DiskCapacity(context) == nil)
}

@Test func diskCapacityCountsPurgeableSpaceAsAvailableAsFinderDoes() {
    var context = VolumeContext(root: URL(fileURLWithPath: "/"), scope: "test")
    context.capacity = 500_000_000_000
    context.available = 100_000_000_000  // free right now
    context.availableForImportantUsage = 140_000_000_000  // plus 40 GB purgeable
    let capacity = try! #require(DiskCapacity(context))
    #expect(capacity.available == 140_000_000_000 && capacity.used == 360_000_000_000)
    context.available = nil
    #expect(DiskCapacity(context)?.available == 140_000_000_000)
}

@Test func diskCapacityFiguresAddUpAsShown() throws {
    // Rounded one by one, 950.15 GB used would print as 950.2 next to 50.3 available and 1000.4 total. Used is the
    // shown total less the shown available instead, so the line always adds up.
    let cases: [(total: UInt64, available: UInt64, caption: String)] = [
        (494_380_000_000, 123_450_000_000, "371 GB used · 123 GB available · 494 GB total"),
        (1_000_400_000_000, 50_250_000_000, "950.1 GB used · 50.3 GB available · 1,000.4 GB total"),
        (2_000_000_000_000, 1_250_000_000_000, "750 GB used · 1,250 GB available · 2,000 GB total"),
        (245_107_195_904, 18_449_000_000, "226.7 GB used · 18.4 GB available · 245.1 GB total"),
        (500_000_000_000, 0, "500 GB used · 0 GB available · 500 GB total"),
    ]
    for item in cases {
        var context = VolumeContext(root: URL(fileURLWithPath: "/"), scope: "test")
        context.capacity = Int64(item.total)
        context.availableForImportantUsage = Int64(item.available)
        let capacity = try #require(DiskCapacity(context))
        #expect(capacity.caption == item.caption)
        let numbers = capacity.caption.split(separator: "·").compactMap {
            Double(($0.split(separator: " ").first ?? "").replacingOccurrences(of: ",", with: ""))
        }
        #expect(numbers.count == 3 && abs(numbers[0] + numbers[1] - numbers[2]) < 0.001, "\(capacity.caption)")
    }
}

@Test func inspectorExplainsSeparateDimensionsAndHardLinkOwner() {
    let fixture = PresentationFixtures.scenario(.limited)
    let alias = settledRow(fixture, named: "Archive link")!
    let presentation = present(alias, in: fixture)
    let fields = InspectorPresentation.fields(
        for: alias, presentation: presentation, provisional: false,
        path: "/Users/Example/Archive link", ownerName: "Archive", records: [])
    let byLabel = Dictionary(uniqueKeysWithValues: fields.map { ($0.label, $0.value) })
    #expect(byLabel["Hard link"]?.contains("“Archive”") == true)
    #expect(byLabel["Classification"] != nil && byLabel["Coverage"] != nil && byLabel["Operations"] != nil)
    let denied = settledRow(fixture, named: "Denied")!
    let records = fixture.result.coverage.records.filter { $0.nodeID == denied.node.id }
    #expect(!records.isEmpty)
    let deniedFields = InspectorPresentation.fields(
        for: denied, presentation: present(denied, in: fixture), provisional: false,
        path: nil, ownerName: nil, records: records)
    #expect(deniedFields.first { $0.label == "Coverage" }!.value.contains("no access"))
    #expect(deniedFields.first { $0.label == "Location" }!.value == "Shown when the scan finishes")
    let sparse = settledRow(fixture, named: "Sparse image")!
    let sparseFields = InspectorPresentation.fields(
        for: sparse, presentation: present(sparse, in: fixture), provisional: false,
        path: nil, ownerName: nil, records: [])
    #expect(sparseFields.first { $0.label == "Logical" }!.value.contains("sparse"))
}

@Test func copyNeverImpliesUnsupportedClaims() {
    var strings = [ProductCopy.helpBody, ProductCopy.helpTitle, ProductCopy.Ready.privacy, ScanDetails.sizesNote]
    for scenario in PresentationScenario.allCases {
        let fixture = PresentationFixtures.scenario(scenario)
        for phase in [ScanPhase.scanning, .stopping, .settled] {
            if let banner = StatusPresentation.outcome(
                phase: phase, progress: fixture.result.progress, scopeName: "Example")
            {
                strings += [banner.title, banner.detail]
            }
        }
        if let banner = StatusPresentation.freshness(.stale) { strings += [banner.title, banner.detail] }
        for row in fixture.snapshot.rows {
            let value = RowPresentation(row: row, provisional: fixture.snapshot.provisional, scopeAllocated: 1)
            strings += [
                value.detail, value.allocated.text, value.coverage, value.classification, value.operation,
                value.accessibility,
            ]
            strings += InspectorPresentation.fields(
                for: row, presentation: value, provisional: fixture.snapshot.provisional,
                path: nil, ownerName: nil, records: []
            ).map(\.value)
        }
    }
    for status in [NodeCoverageStatus.measured, .partial, .policyExcluded, .denied, .unavailable, .notYetScanned] {
        strings += [PresentationLabels.coverage(status), PresentationLabels.coverageDetail(status)]
    }
    for class_ in [ContentClassification.personal, .applicationManaged, .developerManaged, .systemManaged] {
        strings += [PresentationLabels.classification(class_), PresentationLabels.classificationDetail(class_)]
    }
    let forbidden = [
        "Reserved", "System Data", "reclaim", "safe to delete", "Clean up", "free up", "Empty Trash",
    ]
    for text in strings {
        for term in forbidden { #expect(!text.localizedCaseInsensitiveContains(term), "“\(text)” contains “\(term)”") }
    }
    // The named Help command is a privacy policy. Keep scanner policy jargon out of the surrounding copy.
    strings += CoverageIssue.allCases.map(PresentationLabels.issue) + [ScanDetails.sizesNote]
    let jargon = [
        "provisional", "checkpoint", "discovery order", "settle", "lower bound", "events, not unique",
        "inspection only", "eligible later", "policy", "enumeration",
    ]
    for text in strings {
        let copy = text.replacingOccurrences(of: "Help > \(ProductCopy.privacyPolicyTitle)", with: "")
        for term in jargon { #expect(!copy.localizedCaseInsensitiveContains(term), "“\(text)” contains “\(term)”") }
    }
    #expect(ProductCopy.Ready.privacy.contains("without reading file contents"))
}
