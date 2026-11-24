import AppKit
import SpacewiseCore

private func symbol(_ name: String, _ description: String?) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: description)
}

/// Every cell keeps its content the same distance from the column edges, so text lines up under the headers.
private enum CellInset {
    static let leading = Spacing.xs
    static let trailing = Spacing.xs
}

/// Pins `content` inside `cell` with the shared insets, centred vertically. Right-aligned content hugs the trailing
/// edge; the rest the leading edge.
@MainActor private func pin(_ content: NSView, in cell: NSView, alignRight: Bool) {
    content.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(content)
    let leading = content.leadingAnchor
    let trailing = content.trailingAnchor
    NSLayoutConstraint.activate([
        alignRight
            ? leading.constraint(greaterThanOrEqualTo: cell.leadingAnchor, constant: CellInset.leading)
            : leading.constraint(equalTo: cell.leadingAnchor, constant: CellInset.leading),
        alignRight
            ? trailing.constraint(equalTo: cell.trailingAnchor, constant: -CellInset.trailing)
            : trailing.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -CellInset.trailing),
        content.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
}

/// Two-line name cell: icon, name (middle-truncated) and a secondary line explaining special states.
final class NameCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        name.lineBreakMode = .byTruncatingMiddle
        name.font = Typography.body
        detail.lineBreakMode = .byTruncatingTail
        detail.font = Typography.caption
        detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.s
        pin(row, in: self, alignRight: false)
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        textField = name
        imageView = icon
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ row: RowPresentation, coverage: NodeCoverageStatus) {
        name.stringValue = row.name
        detail.stringValue = row.detail
        icon.image = symbol(row.symbol, row.kindLabel)
        icon.contentTintColor =
            row.coverageNeedsAttention
            ? .systemOrange
            : (row.canDrill ? .controlAccentColor : .secondaryLabelColor)
        toolTip = row.name
        setAccessibilityElement(false)
    }
}

/// Right-aligned size. Lower bounds, unknown and not-counted values read differently in text, not only in color.
/// An item that was not fully read carries a small mark before its size that says why.
final class SizeCell: NSTableCellView {
    private let mark = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.alignment = .right
        label.font = Typography.numericSecondary
        label.lineBreakMode = .byTruncatingHead
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        mark.setContentHuggingPriority(.required, for: .horizontal)
        mark.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [mark, label])
        stack.orientation = .horizontal
        stack.spacing = Spacing.xs
        stack.alignment = .centerY
        pin(stack, in: self, alignRight: true)
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ size: SizeText, exactBytes: UInt64, coverage: CoverageMark?) {
        label.stringValue = size.text
        label.textColor = size.kind == .exact ? .labelColor : .secondaryLabelColor
        let sizeTip = size.kind == .exact ? SizeFormat.exact(exactBytes) : size.spoken.capitalized
        if let coverage {
            mark.isHidden = false
            mark.image = symbol(coverage.symbol, coverage.explanation)
            mark.contentTintColor = coverage.attention ? .systemOrange : .secondaryLabelColor
            mark.toolTip = coverage.explanation
            mark.setAccessibilityElement(true)
            mark.setAccessibilityRole(.image)
            mark.setAccessibilityLabel(coverage.explanation)
            toolTip = "\(sizeTip)\n\(coverage.explanation)"
        } else {
            mark.isHidden = true
            mark.toolTip = nil
            mark.setAccessibilityElement(false)
            toolTip = sizeTip
        }
        setAccessibilityElement(false)
    }
}

/// A right-aligned count of the entries inside a folder; blank for files.
final class CountCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.alignment = .right
        label.font = Typography.numericSecondary
        pin(label, in: self, alignRight: true)
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ count: Int?, isContainer: Bool) {
        if let count {
            label.stringValue = SizeFormat.count(UInt64(count))
            label.textColor = .labelColor
            toolTip = ProductCopy.ItemsColumn.spoken(count)
        } else {
            // A folder whose entries are not counted yet (while scanning) reads differently from a file, which has none.
            label.stringValue = isContainer ? ProductCopy.ItemsColumn.unknown : ""
            label.textColor = .secondaryLabelColor
            toolTip = nil
        }
        setAccessibilityElement(false)
    }
}

final class ShareBar: NSView {
    /// The bar's one width: its intrinsic size and its constraint agree.
    static let width: CGFloat = 40
    static let height: CGFloat = 6

    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: Self.height) }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Self.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()
        var fill = bounds
        fill.size.width = max(Self.height / 2, bounds.width * CGFloat(fraction))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

final class ShareCell: NSTableCellView {
    private let bar = ShareBar()
    private let label = NSTextField(labelWithString: "")

    /// Wide enough for the longest text `ShareFormat.percent` produces ("100.0%" or "< 0.1%") in the cell's font,
    /// plus the text field's own padding on each side.
    static let labelWidth: CGFloat = {
        let widest =
            [ShareFormat.percent(1), ShareFormat.percent(0)]
            .map { ($0 as NSString).size(withAttributes: [.font: Typography.numericCaption]).width }.max() ?? 0
        return ceil(widest) + 2 * labelPadding
    }()
    private static let labelPadding: CGFloat = 2
    /// The column width that shows the bar and the longest label without clipping.
    static let fittingWidth = CellInset.leading + ShareBar.width + Spacing.s + labelWidth + CellInset.trailing

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = Typography.numericCaption
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [bar, label])
        stack.orientation = .horizontal
        stack.spacing = Spacing.s
        stack.alignment = .centerY
        pin(stack, in: self, alignRight: false)
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: Self.labelWidth),
            bar.widthAnchor.constraint(equalToConstant: ShareBar.width),
            bar.heightAnchor.constraint(equalToConstant: ShareBar.height),
        ])
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ share: Double?) {
        bar.isHidden = share == nil
        if let share {
            bar.fraction = share
            label.stringValue = ProductCopy.List.share(share)
            toolTip = ProductCopy.List.shareCellTip
        } else {
            label.stringValue = ProductCopy.List.noShare
            toolTip = nil
        }
        setAccessibilityElement(false)
    }
}

/// Plain text, used for the optional Classification and Operations columns.
final class TagCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = Typography.secondary
        label.lineBreakMode = .byTruncatingTail
        pin(label, in: self, alignRight: false)
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(text: String, tip: String) {
        label.stringValue = text
        label.textColor = .labelColor
        toolTip = tip
        setAccessibilityElement(false)
    }
}
