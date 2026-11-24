import AppKit
import SpacewiseCore

/// The screen before the first scan: the mark, one sentence, the two ways to scan, how full the startup disk is, and
/// one quiet line about privacy. Longer explanations live in Help.
final class ReadyView: NSView {
    let scanButton = NSButton(title: ProductCopy.Ready.scanButton, target: nil, action: nil)
    let folderButton = NSButton(title: ProductCopy.Ready.folderButton, target: nil, action: nil)
    private let capacityBar = CapacityBar()
    private let capacityCaption = NSTextField(labelWithString: "")
    /// The content column's width; every line fits inside it.
    private static let columnWidth: CGFloat = 480
    private static let markSize: CGFloat = 64

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSStackView(views: [mark(), title(), subtitle(), choices(), capacity(), privacy()])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Spacing.xl
        let views = column.arrangedSubviews
        column.setCustomSpacing(Spacing.l, after: views[0])
        column.setCustomSpacing(Spacing.s, after: views[1])
        column.setCustomSpacing(Spacing.l, after: views[4])
        column.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        scroll.documentView = document
        addSubview(scroll)
        // The column sits in the middle of the window when it fits, and scrolls from the top when it does not.
        let fillHeight = document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
        fillHeight.priority = .defaultLow
        let centered = column.centerYAnchor.constraint(equalTo: document.centerYAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            fillHeight,
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            centered,
            column.topAnchor.constraint(greaterThanOrEqualTo: document.topAnchor, constant: Spacing.xl),
            column.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -Spacing.xl),
            column.widthAnchor.constraint(equalToConstant: Self.columnWidth),
        ])
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)
        setAccessibilityLabel(ProductCopy.Ready.accessibility)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The startup disk's used and available space, or a line saying it is unavailable.
    func showCapacity(_ capacity: DiskCapacity?) {
        capacityBar.isHidden = capacity == nil
        capacityBar.fraction = capacity?.usedFraction ?? 0
        capacityBar.setAccessibilityValue(capacity?.spoken)
        capacityCaption.stringValue = capacity?.caption ?? DiskCapacity.unavailable
    }

    private func mark() -> NSView {
        let mark = NSImageView(image: NSApp.applicationIconImage)
        mark.setAccessibilityElement(false)
        mark.widthAnchor.constraint(equalToConstant: Self.markSize).isActive = true
        mark.heightAnchor.constraint(equalToConstant: Self.markSize).isActive = true
        return mark
    }

    private func title() -> NSView {
        let title = NSTextField(wrappingLabelWithString: ProductCopy.Ready.title)
        title.font = Typography.hero
        title.preferredMaxLayoutWidth = Self.columnWidth
        return title
    }

    private func subtitle() -> NSView {
        let subtitle = NSTextField(wrappingLabelWithString: ProductCopy.Ready.subtitle)
        subtitle.font = Typography.body
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = Self.columnWidth
        return subtitle
    }

    /// The two scan buttons side by side; Scan Startup Disk is the default.
    private func choices() -> NSView {
        scanButton.bezelStyle = .push
        scanButton.controlSize = .large
        scanButton.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
        scanButton.imagePosition = .imageLeading
        scanButton.keyEquivalent = "\r"
        scanButton.setAccessibilityLabel(ProductCopy.Ready.scanButton)
        scanButton.setAccessibilityHelp(ProductCopy.Ready.scanButtonHelp)
        folderButton.bezelStyle = .push
        folderButton.controlSize = .large
        folderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folderButton.imagePosition = .imageLeading
        folderButton.setAccessibilityLabel(ProductCopy.Ready.folderButton)
        folderButton.setAccessibilityHelp(ProductCopy.Ready.folderButtonHelp)
        let choices = NSStackView(views: [scanButton, folderButton])
        choices.orientation = .horizontal
        choices.spacing = Spacing.m
        return choices
    }

    /// A bar of the startup disk's used space over its total, with the figures under it.
    private func capacity() -> NSView {
        let heading = NSTextField(labelWithString: ProductCopy.Scope.startupDisk)
        heading.font = Typography.heading
        capacityBar.setAccessibilityLabel(ProductCopy.Scope.startupDisk)
        capacityCaption.font = Typography.numericSecondary
        capacityCaption.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, capacityBar, capacityCaption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.s
        capacityBar.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true
        return stack
    }

    private func privacy() -> NSView {
        let line = NSTextField(wrappingLabelWithString: ProductCopy.Ready.privacy)
        line.font = Typography.caption
        line.textColor = .secondaryLabelColor
        line.preferredMaxLayoutWidth = Self.columnWidth
        return line
    }
}

/// A horizontal bar: the used share in the brand violet over a quiet track. VoiceOver reads it as a level.
final class CapacityBar: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }
    private static let height: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let shown = min(1, max(0, fraction))
        guard shown > 0 else { return }
        // A sliver of use still shows as a dot rather than vanishing.
        let width = max(bounds.height, bounds.width * shown)
        Brand.violet.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: radius,
            yRadius: radius
        ).fill()
    }
}
