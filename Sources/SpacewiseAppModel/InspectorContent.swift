import SpacewiseCore

/// What the inspector shows for one selected row: short labelled values, the longer explanations kept behind its
/// "About these fields" disclosure, and whether the row has a location to copy or reveal.
public struct InspectorContent: Sendable, Equatable {
    /// Short facts: a value of a few words each, except paths.
    public let fields: [InspectorField]
    /// What the facts mean, one explanation per topic. Shown only when the person opens the disclosure.
    public let notes: [InspectorField]
    public let canReveal: Bool

    public init(fields: [InspectorField], notes: [InspectorField] = [], canReveal: Bool) {
        self.fields = fields
        self.notes = notes
        self.canReveal = canReveal
    }

    public static let empty = InspectorContent(fields: [], canReveal: false)

    /// While a scan is live the rows carry no path, so only a settled result supplies locations, item counts and
    /// records.
    public static func make(
        row: ScopeRow, presentation p: RowPresentation, result: ScanResult?,
        isLive: Bool
    ) -> InspectorContent {
        let settled = isLive ? nil : result
        let id = row.node.id
        let path = settled?.displayPath(for: id) ?? settled?.url(for: id)?.path
        let copy = ProductCopy.InspectorFields.self
        let isManagedGroup = settled?.namespace.unified == true && id == LogicalNamespace.managedGroupID

        var fields = [
            InspectorField(label: copy.kind, value: p.kindLabel),
            InspectorField(label: copy.size, value: p.allocated.text),
        ]
        if p.logical.text != p.allocated.text {
            fields.append(InspectorField(label: copy.logical, value: p.logical.text))
        }
        if let share = p.share { fields.append(InspectorField(label: copy.share, value: ShareFormat.percent(share))) }
        if let count = settled?.itemCount(of: id) {
            fields.append(InspectorField(label: copy.items, value: SizeFormat.count(UInt64(count))))
        }
        fields.append(InspectorField(label: copy.coverage, value: p.coverage))
        fields.append(InspectorField(label: copy.classification, value: p.classification))
        if p.isHardLinkAlias {
            let owner = row.node.hardLinkOwner.flatMap { settled?.node(for: $0)?.name }
            fields.append(
                InspectorField(
                    label: copy.hardLink,
                    value: owner.map(copy.hardLinkOwner) ?? copy.hardLinkElsewhere))
        }
        if let path, !isManagedGroup {
            fields.append(InspectorField(label: copy.location, value: path, role: .location))
        }
        if let settled, settled.namespace.unified { fields += unifiedFields(for: id, in: settled) }

        var notes: [InspectorField] = []
        if isManagedGroup, let settled { notes += managedGroupNotes(in: settled) }
        notes += explanations(
            row: row, presentation: p, records: settled?.coverage.records.filter { $0.nodeID == id } ?? [],
            provisional: isLive)
        return InspectorContent(fields: fields, notes: notes, canReveal: path != nil)
    }

    /// One explanation per topic, in the order of the fields they explain.
    static func explanations(
        row: ScopeRow, presentation p: RowPresentation, records: [CoverageRecord],
        provisional: Bool
    ) -> [InspectorField] {
        let copy = ProductCopy.InspectorFields.self
        var notes: [InspectorField] = []
        if p.allocated.kind == .exact, p.logical.kind == .exact {
            var sizes = copy.exactSizes(
                allocated: SizeFormat.exact(row.node.allocatedBytes),
                logical: SizeFormat.exact(row.node.logicalBytes))
            if row.node.logicalBytes > row.node.allocatedBytes { sizes += " " + copy.logicalLarger }
            if row.node.logicalBytes < row.node.allocatedBytes { sizes += " " + copy.logicalSmaller }
            notes.append(InspectorField(label: copy.aboutSizes, value: sizes))
        } else if p.allocated.kind == .lowerBound {
            notes.append(InspectorField(label: copy.aboutSizes, value: copy.lowerBound))
        }
        var coverage = PresentationLabels.coverageDetail(row.coverage)
        if let issue = row.node.issue { coverage += " " + copy.coverageReason(PresentationLabels.issue(issue)) }
        var reasons: [CoverageIssue] = row.node.issue.map { [$0] } ?? []
        for record in records where !reasons.contains(record.reason) && reasons.count < 3 {
            reasons.append(record.reason)
            coverage += " " + copy.coverageReason(PresentationLabels.issue(record.reason))
        }
        notes.append(InspectorField(label: copy.aboutCoverage, value: coverage))
        notes.append(
            InspectorField(
                label: copy.aboutClassification,
                value: PresentationLabels.classificationDetail(row.classification)))
        notes.append(
            InspectorField(
                label: copy.aboutOperations,
                value: PresentationLabels.operationDetail(provisional ? .inspectionOnly : row.eligibility)))
        if provisional { notes.append(InspectorField(label: copy.aboutScanning, value: copy.scanning)) }
        return notes
    }

    /// Unified-drive facts: where the item physically lives, and what the managed group measured.
    static func unifiedFields(for id: Int, in result: ScanResult) -> [InspectorField] {
        let copy = ProductCopy.Inspector.self
        if id == LogicalNamespace.managedGroupID {
            let measured = result.measuredCategories()[.systemManaged]
            let value = measured.map { SizeFormat.bytes($0.allocatedBytes) } ?? copy.managedGroupNothingMeasured
            return [
                InspectorField(label: ProductCopy.InspectorFields.measured, value: value),
                InspectorField(
                    label: copy.physicalLocationsLabel,
                    value: result.physicalPaths(for: id).joined(separator: "\n"), role: .paths),
            ]
        }
        let physical = result.physicalPaths(for: id)
        guard physical.count > 1 || physical.first != result.displayPath(for: id) else { return [] }
        let label = physical.count > 1 ? copy.storedOnBothVolumesLabel : copy.physicalLocationLabel
        return [InspectorField(label: label, value: physical.joined(separator: "\n"), role: .paths)]
    }

    /// What the managed group is, and what it does not measure.
    static func managedGroupNotes(in result: ScanResult) -> [InspectorField] {
        let copy = ProductCopy.Inspector.self
        let measured = result.measuredCategories()[.systemManaged]
        let attributed =
            measured.map {
                copy.managedGroupMeasured(
                    SizeFormat.bytes($0.allocatedBytes), exact: SizeFormat.exact($0.allocatedBytes))
            } ?? copy.managedGroupNothingMeasured
        let ending =
            measured?.allocationUnknown == true ? copy.managedGroupLowerBoundEnding : copy.managedGroupExactEnding
        return [
            InspectorField(label: copy.whatThisIsLabel, value: copy.managedGroupWhatThisIs),
            // Stands in for the location field, which the group does not have.
            InspectorField(
                label: ProductCopy.InspectorFields.location, value: copy.managedGroupLocation, role: .location),
            InspectorField(label: copy.measuredLabel, value: attributed + ending),
            InspectorField(label: copy.notMeasuredLabel, value: copy.managedGroupNotMeasured),
        ]
    }
}
