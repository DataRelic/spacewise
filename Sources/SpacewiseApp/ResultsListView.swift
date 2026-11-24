import AppKit
import SpacewiseAppModel
import SpacewiseCore

/// The item table: Return opens the selection, Space previews it, Escape clears it, Copy copies its path, and a
/// secondary click selects the row under the pointer before showing the row menu (as Finder does).
final class ResultsTableView: NSTableView {
    var isListCollapsed = false

    override var acceptsFirstResponder: Bool {
        !isListCollapsed && !isHiddenOrHasHiddenAncestor && super.acceptsFirstResponder
    }

    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    var onCopy: (() -> Void)?
    var canCopy: () -> Bool = { false }
    /// The menu for the selected row, built when it is about to open.
    var rowMenu: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if KeyCode.isReturn(event.keyCode), selectedRow >= 0 {
            onReturn?()
        } else if event.keyCode == KeyCode.space, event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            onSpace?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if row != selectedRow { selectRowIndexes([row], byExtendingSelection: false) }
        return rowMenu?(row)
    }

    override func cancelOperation(_ sender: Any?) { deselectAll(nil) }

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 && canCopy() }
        // One row at a time: there is nothing more for Select All to select.
        if item.action == #selector(selectAll(_:)) { return false }
        return super.validateUserInterfaceItem(item)
    }
}

/// The list's column header, painted solid. Since macOS 11 rows scroll up under a table's header, which floats over
/// them on a translucent material. In a live window the material blurs the rows; anything that renders the window
/// without the material (screenshots of the view, Reduce Transparency edge cases) shows the rows straight through the
/// column titles. A solid header reads the same everywhere.
final class OpaqueTableHeaderView: NSTableHeaderView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

/// What the list shows: its rows, whether they are provisional, and the scope total shares are measured against.
struct ListContent {
    var source: RowSource?
    var provisional = false
    var scopeAllocated: UInt64 = 0
    /// The number of entries inside a folder row, when known.
    var itemCount: (ScanNode) -> Int? = { _ in nil }
}

/// The item list under the map: the table with its columns, and the empty state shown in its place.
/// It owns the table's data source; selection decisions stay with its owner, which hears every change.
@MainActor final class ResultsListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// The table's saved column layout (order, widths, hidden columns, sort). Named for this column set, so a layout
    /// saved before the set changed is not applied to it.
    static let autosaveName = "SpacewiseItemList"

    let table = ResultsTableView()
    private let scroll = NSScrollView()
    private let emptyView = NSStackView()
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    /// Read by the table's data source whenever it asks; set before every render.
    var content = ListContent()
    /// The table's own selection changed (a click, the keyboard, or a programmatic change).
    var onSelectionChange: (() -> Void)?
    /// The person clicked a column header to sort; nil means the list's own order.
    var onSortChange: ((ListSort?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        configureTable()
        configureEmptyState()
        addSubview(scroll)
        addSubview(emptyView)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyView.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Spacing.m),
            emptyView.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configureTable() {
        for column in ResultsColumn.allCases { table.addTableColumn(column.makeTableColumn()) }
        table.headerView = OpaqueTableHeaderView(frame: table.headerView?.frame ?? .zero)
        table.autosaveName = Self.autosaveName
        table.autosaveTableColumns = true
        let headerMenu = NSMenu(title: ProductCopy.Commands.columns)
        headerMenu.delegate = self
        table.headerView?.menu = headerMenu
        table.dataSource = self
        table.delegate = self
        table.style = .fullWidth
        table.rowHeight = SplitPolicy.rowHeight
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel(ProductCopy.List.accessibility)
        table.target = nil
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureEmptyState() {
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .light)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyTitle.font = Typography.title
        emptyDetail.font = Typography.body
        emptyDetail.textColor = .secondaryLabelColor
        emptyDetail.alignment = .center
        emptyDetail.preferredMaxLayoutWidth = 380
        emptyView.setViews([emptyIcon, emptyTitle, emptyDetail], in: .center)
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = Spacing.s
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        emptyView.setAccessibilityElement(true)
        emptyView.setAccessibilityRole(.group)
    }

    /// Shows `empty` in place of the table when there are no rows to list.
    func showEmptyState(_ empty: EmptyScope?, rowCount: Int) {
        if let empty, rowCount == 0 {
            // A hidden first responder hands focus to the next view in the key loop, the toolbar's filter field; the
            // window takes it instead, and it returns to the list with the rows (MainViewController.placeDefaultFocus).
            if let window, window.firstResponder === table { window.makeFirstResponder(nil) }
            emptyView.isHidden = false
            scroll.isHidden = true
            emptyIcon.image = NSImage(systemSymbolName: empty.symbol, accessibilityDescription: nil)
            emptyTitle.stringValue = empty.title
            emptyDetail.stringValue = empty.detail
            emptyView.setAccessibilityLabel("\(empty.title). \(empty.detail)")
        } else {
            emptyView.isHidden = true
            scroll.isHidden = false
        }
    }

    // MARK: Selection

    /// The listed row the table has selected.
    var selectedRow: ScopeRow? {
        guard table.selectedRow >= 0 else { return nil }
        return content.source?.row(at: table.selectedRow)
    }

    /// The row a context click landed on, if the table is handling one.
    var clickedRow: ScopeRow? {
        table.clickedRow >= 0 ? content.source?.row(at: table.clickedRow) : nil
    }

    var hasClickedRow: Bool { table.clickedRow >= 0 }

    /// Selects the row that lists `node`, or clears the selection when it is not listed. Returns whether it was listed.
    @discardableResult func select(node: Int?, scroll: Bool) -> Bool {
        guard let node, let index = content.source?.index(ofNode: node) else {
            table.deselectAll(nil)
            return false
        }
        table.selectRowIndexes([index], byExtendingSelection: false)
        if scroll { table.scrollRowToVisible(index) }
        return true
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { content.source?.count ?? 0 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        if let scopeRow = content.source?.row(at: row) {
            let presentation = RowPresentation(
                row: scopeRow, provisional: content.provisional,
                scopeAllocated: content.scopeAllocated)
            rowView.setAccessibilityLabel(presentation.accessibility)
        }
        return rowView
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        content.source?.row(at: row)?.node.name
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let tableColumn, let column = ResultsColumn(tableColumn.identifier),
            let row = content.source?.row(at: index)
        else { return nil }
        let provisional = content.provisional
        let presentation = RowPresentation(row: row, provisional: provisional, scopeAllocated: content.scopeAllocated)
        let count = column == .items ? content.itemCount(row.node) : nil
        return column.cell(
            in: tableView, owner: self, row: row, presentation: presentation, provisional: provisional,
            itemCount: count)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { onSelectionChange?() }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        onSortChange?(currentSort)
    }

    /// The sort the table's headers show, restored with the saved layout or set by a header click.
    var currentSort: ListSort? { ResultsColumn.sort(from: table.sortDescriptors.first) }

    // MARK: Columns

    func isColumnShown(_ column: ResultsColumn) -> Bool {
        table.tableColumn(withIdentifier: column.identifier)?.isHidden == false
    }

    func setColumn(_ column: ResultsColumn, shown: Bool) {
        guard column.canHide, let tableColumn = table.tableColumn(withIdentifier: column.identifier) else { return }
        tableColumn.isHidden = !shown
    }

    /// The header's menu lists every column that can be hidden, ticked when shown.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in ResultsColumn.allCases where column.canHide {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = isColumnShown(column) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = ResultsColumn(rawValue: raw) else { return }
        setColumn(column, shown: !isColumnShown(column))
    }
}
