import AppKit
import SpacewiseAppModel
import SpacewiseCore

/// The file types on the map, largest first, in a real table beside it: colour swatch (with the map's pattern for
/// structural groups), name, size, item count and a share bar. Selecting a row highlights that type on the map;
/// selecting it again or pressing Esc clears it. The highlight itself belongs to the owner (`TypeHighlight`); this
/// view only reports choices and shows what it is told.
@MainActor final class FileTypeListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// The person chose a type (or nil to clear). The owner applies `TypeHighlight.choose` and calls `show(_:)`.
    var onChoose: ((FileCategory?) -> Void)?
    let table = FileTypeTable()
    private let scroll = NSScrollView()
    private let title = NSTextField(labelWithString: ProductCopy.FileTypes.title)
    private(set) var rows: [FileTypeRow] = []
    private var showing: FileCategory?
    private var applying = false
    /// The scroll view's height: always a whole number of rows, so the last row shown is never cut through.
    private var scrollHeight: NSLayoutConstraint!
    static let width: CGFloat = 224
    private static let rowHeight: CGFloat = 38

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = Typography.captionEmphasis
        title.textColor = .secondaryLabelColor
        title.setAccessibilityElement(false)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .default
        table.dataSource = self
        table.delegate = self
        table.onRepeatSelection = { [weak self] row in self?.chooseAgain(row) }
        table.onCancel = { [weak self] in self?.onChoose?(nil) }
        table.setAccessibilityLabel(ProductCopy.FileTypes.accessibility)
        table.setAccessibilityHelp(ProductCopy.FileTypes.help)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalLineScroll = Self.rowHeight
        for item in [title, scroll] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        // Below the bottom edge: a map shorter than one row clips the row rather than breaking the layout.
        scrollHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.xs),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Spacing.xs),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            scrollHeight,
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Fits the list to the room beside the map in whole rows. When not every row fits, the list scrolls (by a row per
    /// line step) and its scroller shows that more follow. Updated when the size or the rows change, outside the layout
    /// pass, so the new height applies in the same pass rather than the next one.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitRows()
    }

    private var rowsThatFit: Int {
        let room = bounds.height - title.intrinsicContentSize.height - Spacing.xs
        return max(1, Int(room / Self.rowHeight))
    }

    private func fitRows() {
        let height = CGFloat(min(rowsThatFit, max(rows.count, 1))) * Self.rowHeight
        if scrollHeight.constant != height { scrollHeight.constant = height }
    }

    /// New rows for a new map. The highlighted type is re-selected when it is still listed.
    func set(_ new: [FileTypeRow]) {
        guard new != rows else { return }
        rows = new
        applying = true
        table.reloadData()
        applying = false
        show(showing)
        fitRows()
    }

    /// Reflect the owner's highlight without reporting it back.
    func show(_ category: FileCategory?) {
        showing = category
        applying = true
        defer { applying = false }
        if let category, let index = rows.firstIndex(where: { $0.category == category }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
        }
    }

    private func chooseAgain(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        onChoose?(rows[row].category)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for row in 0..<table.numberOfRows {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileTypeCell)?.needsDisplay = true
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("FileTypeCell")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? FileTypeCell
            ?? FileTypeCell(identifier: identifier)
        cell.configure(rows[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applying else { return }
        let index = table.selectedRow
        let chosen = rows.indices.contains(index) ? rows[index].category : nil
        if chosen == nil {
            onChoose?(nil)
        } else if chosen != showing {
            onChoose?(chosen)
        }
    }
}

/// The type table: clicking the selected row again and Esc both clear the selection, as WinDirStat's list does.
@MainActor final class FileTypeTable: NSTableView {
    var onRepeatSelection: ((Int) -> Void)?
    var onCancel: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, row == selectedRow, !event.modifierFlags.contains(.command) {
            window?.makeFirstResponder(self)
            onRepeatSelection?(row)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.escape {
            cancelOperation(nil)
        } else if event.charactersIgnoringModifiers == " ", selectedRow >= 0 {
            onRepeatSelection?(selectedRow)  // Space toggles the selected type, like a second click
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard selectedRow >= 0 else { return }
        onCancel?()
    }

    /// The click that activates an inactive window also chooses the row under it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One file type: swatch, name and size on the first line; share bar, percentage and count on the second.
@MainActor final class FileTypeCell: NSTableCellView {
    private let swatch = TypeSwatch()
    private let name = NSTextField(labelWithString: "")
    private let size = NSTextField(labelWithString: "")
    private let bar = TypeShareBar()
    private let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        name.font = Typography.secondary
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        size.font = Typography.numericSecondary
        size.alignment = .right
        size.setContentCompressionResistancePriority(.required, for: .horizontal)
        size.setContentHuggingPriority(.required, for: .horizontal)
        detail.font = Typography.numericCaption
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for item in [swatch, name, size, bar, detail] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.setAccessibilityElement(false)
            addSubview(item)
        }
        let textLeading = Spacing.xs + 12 + Spacing.s
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.xs),
            swatch.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 12),
            swatch.heightAnchor.constraint(equalToConstant: 12),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textLeading),
            name.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.xs),
            size.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: Spacing.xs),
            size.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.s),
            size.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            bar.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            bar.widthAnchor.constraint(equalToConstant: 48),
            bar.heightAnchor.constraint(equalToConstant: 5),
            bar.centerYAnchor.constraint(equalTo: detail.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: Spacing.s),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.s),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor),
        ])
        textField = name
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ row: FileTypeRow) {
        swatch.category = row.category
        bar.category = row.category
        bar.fraction = row.share
        name.stringValue = row.category.title
        size.stringValue = SizeFormat.bytes(row.bytes)
        let items = ProductCopy.FileTypes.items(row.items, folders: row.category == .folderBlock)
        detail.stringValue = "\(ProductCopy.FileTypes.share(row.share)) · \(items)"
        toolTip = "\(row.category.title): \(SizeFormat.exact(row.bytes))"
        setAccessibilityLabel(
            ProductCopy.FileTypes.row(
                row.category.title, size: SizeFormat.spoken(row.bytes),
                items: items, share: row.share))
    }

    /// Selected rows use the table's emphasized style; keep the secondary text readable on it.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            detail.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            bar.emphasized = emphasized
        }
    }
}

/// A category's colour, with the map's own pattern for the groups that are not file types, so the list does not rely on
/// colour either.
@MainActor final class TypeSwatch: NSView {
    var category: FileCategory = .other {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDarkAqua
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        TreemapPalette.color(category, dark: dark).nsColor.setFill()
        shape.fill()
        switch category {
        case .managedZone: stripes(clip: shape, color: NSColor.white.withAlphaComponent(0.5), rising: true)
        case .folderBlock, .grouped: stripes(clip: shape, color: NSColor.black.withAlphaComponent(0.3), rising: false)
        default: break
        }
        NSColor.black.withAlphaComponent(dark ? 0.35 : 0.18).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }

    /// Diagonal one-point lines across the swatch, matching the hatch (folder blocks, summed groups) and weave
    /// (system-managed) on the map.
    private func stripes(clip: NSBezierPath, color: NSColor, rising: Bool) {
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        color.setStroke()
        for offset in stride(from: -12, to: 14, by: 4) {
            let line = NSBezierPath()
            let x = bounds.minX + CGFloat(offset)
            line.move(to: CGPoint(x: x, y: rising ? bounds.minY : bounds.maxY))
            line.line(to: CGPoint(x: x + 12, y: rising ? bounds.maxY : bounds.minY))
            line.lineWidth = 1
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The share of the map a type covers, as a small bar in the type's colour.
@MainActor final class TypeShareBar: NSView {
    var category: FileCategory = .other {
        didSet { needsDisplay = true }
    }
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }
    var emphasized = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        (emphasized ? NSColor.white.withAlphaComponent(0.3) : NSColor.quaternaryLabelColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        var fill = bounds
        fill.size.width = max(bounds.height, bounds.width * CGFloat(min(1, max(0, fraction))))
        let color =
            emphasized ? NSColor.white : TreemapPalette.color(category, dark: effectiveAppearance.isDarkAqua).nsColor
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
