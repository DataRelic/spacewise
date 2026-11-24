import AppKit
import SpacewiseCore

/// Explains the selected row: short labelled values in two columns, and the explanations behind one "About these
/// fields" disclosure at the bottom, closed until the person opens it. It stays open or closed across selections.
final class InspectorView: NSView {
    private let heading = NSTextField(labelWithString: ProductCopy.Inspector.heading)
    private let stack = NSStackView()
    private let grid = NSGridView()
    private let aboutToggle = NSButton()
    private let aboutLabel = NSButton(title: ProductCopy.InspectorFields.about, target: nil, action: nil)
    private let aboutRow = NSStackView()
    private let notesStack = NSStackView()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton(title: ProductCopy.Inspector.copyPath, target: nil, action: nil)
    private let revealButton = NSButton(title: ProductCopy.Inspector.showInFinder, target: nil, action: nil)
    private let coverageButton = NSButton(title: ProductCopy.Inspector.scanDetails, target: nil, action: nil)
    private var notes: [InspectorField] = []
    var onCoverage: (() -> Void)?
    var onCopy: (() -> Void)?
    var onReveal: (() -> Void)?
    /// The inspector's fixed width.
    static let width: CGFloat = 300
    /// Room for the values: the inspector less its leading inset, the scroller and the label column.
    private static let textWidth = width - Spacing.m - Spacing.l
    private(set) var aboutExpanded = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        heading.font = Typography.captionEmphasis
        heading.textColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingMiddle
        configureGrid()
        configureAbout()
        stack.setViews([grid, aboutRow, notesStack], in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.m
        stack.setCustomSpacing(Spacing.l, after: grid)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        for button in [copyButton, revealButton, coverageButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        revealButton.target = self
        revealButton.action = #selector(revealTapped)
        coverageButton.target = self
        coverageButton.action = #selector(coverageTapped)
        notice.font = Typography.caption
        notice.textColor = .systemOrange
        notice.isHidden = true
        let buttons = NSStackView(views: [copyButton, revealButton])
        buttons.spacing = Spacing.s
        let bottom = NSStackView(views: [notice, buttons, coverageButton])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = Spacing.s
        let top = NSBox()
        top.boxType = .separator
        for item in [top, heading, scroll, bottom] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.xs),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.m),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.m),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.widthAnchor.constraint(equalToConstant: 1),
            top.topAnchor.constraint(equalTo: topAnchor),
            top.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: Spacing.s),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.m),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -Spacing.s),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.m),
            bottom.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.s),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.xs),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Spacing.l),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Spacing.s),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel(ProductCopy.Inspector.heading)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configureGrid() {
        grid.rowSpacing = Spacing.xs
        grid.columnSpacing = Spacing.s
        grid.xPlacement = .leading
        grid.rowAlignment = .firstBaseline
    }

    private func configureAbout() {
        aboutToggle.bezelStyle = .disclosure
        aboutToggle.setButtonType(.pushOnPushOff)
        aboutToggle.title = ""
        aboutToggle.state = .off
        aboutToggle.target = self
        aboutToggle.action = #selector(aboutTapped)
        aboutToggle.setAccessibilityLabel(ProductCopy.InspectorFields.about)
        // The words toggle too, as a disclosure's label does in Finder's Get Info.
        aboutLabel.isBordered = false
        aboutLabel.font = Typography.caption
        aboutLabel.contentTintColor = .secondaryLabelColor
        aboutLabel.target = self
        aboutLabel.action = #selector(aboutLabelTapped)
        aboutLabel.setAccessibilityElement(false)
        aboutRow.setViews([aboutToggle, aboutLabel], in: .leading)
        aboutRow.orientation = .horizontal
        aboutRow.spacing = Spacing.xs
        aboutRow.alignment = .centerY
        notesStack.orientation = .vertical
        notesStack.alignment = .leading
        notesStack.spacing = Spacing.s
        notesStack.isHidden = true
    }

    func show(
        title: String, fields: [InspectorField], notes: [InspectorField] = [], canReveal: Bool,
        canCoverage: Bool
    ) {
        rebuild(item: title, fields: fields, notes: notes)
        copyButton.isEnabled = canReveal
        revealButton.isEnabled = canReveal
        coverageButton.isEnabled = canCoverage
        copyButton.isHidden = false
        revealButton.isHidden = false
    }

    func showEmpty(canCoverage: Bool) {
        let hint = InspectorField(
            label: ProductCopy.Inspector.selectionLabel, value: ProductCopy.Inspector.selectionHint)
        rebuild(item: nil, fields: [], notes: [])
        let text = NSTextField(wrappingLabelWithString: hint.value)
        text.font = Typography.secondary
        text.textColor = .secondaryLabelColor
        text.preferredMaxLayoutWidth = Self.textWidth
        grid.addRow(with: [text])
        copyButton.isEnabled = false
        revealButton.isEnabled = false
        coverageButton.isEnabled = canCoverage
    }

    func setNotice(_ text: String) {
        notice.stringValue = text
        notice.isHidden = text.isEmpty
    }

    /// `item` is the selected item's name, or nil when nothing is selected (the heading then says only "Inspector").
    private func rebuild(item: String?, fields: [InspectorField], notes: [InspectorField]) {
        heading.stringValue = item.map(ProductCopy.Inspector.heading) ?? ProductCopy.Inspector.heading
        // Removing a grid row leaves its views in place, so take them out first.
        for row in 0..<grid.numberOfRows {
            for column in 0..<grid.numberOfColumns {
                grid.cell(atColumnIndex: column, rowIndex: row).contentView?.removeFromSuperview()
            }
        }
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        while grid.numberOfColumns > 0 { grid.removeColumn(at: 0) }
        let labelWidth = Self.labelColumnWidth(fields)
        for field in fields {
            let caption = NSTextField(labelWithString: field.label)
            caption.font = Typography.caption
            caption.textColor = .secondaryLabelColor
            caption.alignment = .right
            let value = NSTextField(wrappingLabelWithString: field.value)
            value.font = Self.isNumeric(field.value) ? Typography.numericSecondary : Typography.secondary
            value.isSelectable = true
            value.preferredMaxLayoutWidth = Self.textWidth - labelWidth - grid.columnSpacing
            value.maximumNumberOfLines = 0
            // Paths are long: break anywhere rather than overflow.
            if field.role != .detail { value.lineBreakMode = .byCharWrapping }
            value.setAccessibilityLabel(field.label)
            grid.addRow(with: [caption, value])
        }
        if grid.numberOfColumns == 2 {
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = labelWidth
        }
        self.notes = notes
        aboutRow.isHidden = notes.isEmpty
        rebuildNotes()
    }

    /// Wide enough for the longest label in this set, so values line up.
    private static func labelColumnWidth(_ fields: [InspectorField]) -> CGFloat {
        let widest =
            fields.map { ($0.label as NSString).size(withAttributes: [.font: Typography.caption]).width }.max() ?? 0
        return ceil(widest)
    }

    /// Sizes, counts and percentages get fixed-width digits.
    private static func isNumeric(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first(where: { !CharacterSet.whitespaces.contains($0) }) else {
            return false
        }
        return CharacterSet.decimalDigits.contains(first) || "≥<~".unicodeScalars.contains(first)
    }

    private func rebuildNotes() {
        notesStack.arrangedSubviews.forEach {
            notesStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        notesStack.isHidden = !aboutExpanded || notes.isEmpty
        guard aboutExpanded else { return }
        for note in notes {
            let caption = NSTextField(labelWithString: note.label)
            caption.font = Typography.captionEmphasis
            caption.textColor = .secondaryLabelColor
            let value = NSTextField(wrappingLabelWithString: note.value)
            value.font = Typography.caption
            value.textColor = .secondaryLabelColor
            value.isSelectable = true
            value.preferredMaxLayoutWidth = Self.textWidth
            if note.role != .detail { value.lineBreakMode = .byCharWrapping }
            let block = NSStackView(views: [caption, value])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = Spacing.xs
            block.setAccessibilityElement(true)
            block.setAccessibilityRole(.group)
            block.setAccessibilityLabel("\(note.label): \(note.value)")
            notesStack.addArrangedSubview(block)
        }
    }

    func setAboutExpanded(_ expanded: Bool) {
        aboutExpanded = expanded
        aboutToggle.state = expanded ? .on : .off
        rebuildNotes()
    }

    @objc private func aboutTapped() { setAboutExpanded(aboutToggle.state == .on) }
    @objc private func aboutLabelTapped() { setAboutExpanded(!aboutExpanded) }
    @objc private func copyTapped() { onCopy?() }
    @objc private func revealTapped() { onReveal?() }
    @objc private func coverageTapped() { onCoverage?() }
}
