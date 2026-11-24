import AppKit
import SpacewiseAppModel
import SpacewiseCore

/// The item list's columns. Which show by default and how they sort is decided in `ListColumn`; this adds the AppKit
/// parts: titles, widths and cells.
typealias ResultsColumn = ListColumn

extension ListColumn {
    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    init?(_ identifier: NSUserInterfaceItemIdentifier) {
        self.init(rawValue: identifier.rawValue)
    }

    var title: String {
        switch self {
        case .name: ProductCopy.List.nameTitle
        case .allocated: ProductCopy.List.allocatedTitle
        case .logical: ProductCopy.List.logicalTitle
        case .share: ProductCopy.List.shareTitle
        case .items: ProductCopy.ItemsColumn.title
        case .classification: ProductCopy.List.classificationTitle
        case .operations: ProductCopy.List.operationsTitle
        }
    }

    var headerTip: String {
        switch self {
        case .name: ProductCopy.List.nameTip
        case .allocated: ProductCopy.List.allocatedTip
        case .logical: ProductCopy.List.logicalTip
        case .share: ProductCopy.List.shareTip
        case .items: ProductCopy.ItemsColumn.tip
        case .classification: ProductCopy.List.classificationTip
        case .operations: ProductCopy.List.operationsTip
        }
    }

    /// Initial and smallest width in points.
    @MainActor var widths: (initial: CGFloat, minimum: CGFloat) {
        switch self {
        case .name: (240, 160)
        case .allocated: (104, 88)
        case .logical: (104, 88)
        // The bar and its longest label, never clipped.
        case .share: (ceil(ShareCell.fittingWidth) + Spacing.s, ceil(ShareCell.fittingWidth))
        case .items: (72, 56)
        case .classification: (128, 100)
        case .operations: (108, 96)
        }
    }

    /// Numbers read right-aligned, so their headers are too.
    var alignsRight: Bool { self == .allocated || self == .logical || self == .items }

    @MainActor func makeTableColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = widths.initial
        column.minWidth = widths.minimum
        column.headerToolTip = headerTip
        column.resizingMask = [.userResizingMask, .autoresizingMask]
        column.isHidden = !isVisibleByDefault
        if sortKey != nil {
            column.sortDescriptorPrototype = NSSortDescriptor(key: rawValue, ascending: sortsAscendingFirst)
        }
        if alignsRight { column.headerCell.alignment = .right }
        return column
    }

    /// The list sort a table sort descriptor stands for; nil when the descriptor is not one of this list's columns.
    static func sort(from descriptor: NSSortDescriptor?) -> ListSort? {
        guard let key = descriptor?.key, let column = ListColumn(rawValue: key), let sortKey = column.sortKey else {
            return nil
        }
        return ListSort(key: sortKey, ascending: descriptor?.ascending ?? false)
    }

    /// A configured cell for `row`, reusing one the table already made for this column.
    @MainActor func cell(
        in tableView: NSTableView, owner: Any?, row: ScopeRow, presentation p: RowPresentation,
        provisional: Bool, itemCount: Int?
    ) -> NSView {
        func reuse<T: NSTableCellView>(_ make: (NSUserInterfaceItemIdentifier) -> T) -> T {
            (tableView.makeView(withIdentifier: identifier, owner: owner) as? T) ?? make(identifier)
        }
        switch self {
        case .name:
            let cell = reuse(NameCell.init(identifier:))
            cell.configure(p, coverage: row.coverage)
            return cell
        case .allocated:
            let cell = reuse(SizeCell.init(identifier:))
            cell.configure(
                p.allocated, exactBytes: row.node.allocatedBytes, coverage: CoverageMark(row: row, presentation: p))
            return cell
        case .logical:
            let cell = reuse(SizeCell.init(identifier:))
            cell.configure(p.logical, exactBytes: row.node.logicalBytes, coverage: nil)
            return cell
        case .share:
            let cell = reuse(ShareCell.init(identifier:))
            cell.configure(p.share)
            return cell
        case .items:
            let cell = reuse(CountCell.init(identifier:))
            let isContainer = row.node.kind == .directory || row.node.kind == .package
            cell.configure(itemCount, isContainer: isContainer)
            return cell
        case .classification:
            let cell = reuse(TagCell.init(identifier:))
            cell.configure(text: p.classification, tip: PresentationLabels.classificationDetail(row.classification))
            return cell
        case .operations:
            let cell = reuse(TagCell.init(identifier:))
            let eligibility: OperationEligibility = provisional ? .inspectionOnly : row.eligibility
            cell.configure(text: p.operation, tip: PresentationLabels.operationDetail(eligibility))
            return cell
        }
    }
}

/// The small mark beside a size when the item was not fully read, and why. Nil for a fully measured item.
struct CoverageMark {
    let symbol: String
    let attention: Bool
    /// The status and its explanation, for the tooltip and VoiceOver.
    let explanation: String

    init?(row: ScopeRow, presentation: RowPresentation) {
        guard row.coverage != .measured else { return nil }
        symbol = presentation.coverageSymbol
        attention = presentation.coverageNeedsAttention
        explanation = "\(presentation.coverage). \(PresentationLabels.coverageDetail(row.coverage))"
    }
}
