import AppKit
import SpacewiseCore

/// The status above the map. Keep the action buttons together and give the text its own line when needed.
final class BannerView: NSBox {
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private let text = NSStackView()
    private let row = NSStackView()
    private let body = NSStackView()
    private let spacer = NSView()
    private var shownActions: [BannerAction] = []
    private(set) var shown: Banner?
    var onAction: ((BannerAction) -> Void)?
    private static let iconSize: CGFloat = 16
    private static let minimumScanTitleWidth: CGFloat = 110

    init() {
        super.init(frame: .zero)
        boxType = .custom
        titlePosition = .noTitle
        cornerRadius = Spacing.s
        borderWidth = 0
        contentViewMargins = NSSize(width: Spacing.m, height: Spacing.xs)
        titleLabel.font = Typography.body
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = Typography.numericSecondary
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Typography.body.pointSize, weight: .medium)
        let iconSlot = NSView()
        iconSlot.translatesAutoresizingMaskIntoConstraints = false
        for item in [icon, spinner] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            iconSlot.addSubview(item)
        }
        NSLayoutConstraint.activate([
            iconSlot.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconSlot.heightAnchor.constraint(equalToConstant: Self.iconSize),
            icon.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
        ])
        buttons.orientation = .horizontal
        buttons.isHidden = true
        buttons.spacing = Spacing.s
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        text.setViews([titleLabel, detailLabel], in: .leading)
        text.orientation = .horizontal
        text.alignment = .firstBaseline
        text.spacing = Spacing.s
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.setViews([iconSlot, body], in: .leading)
        row.alignment = .centerY
        row.spacing = Spacing.s
        body.setViews([text, spacer, buttons], in: .leading)
        body.alignment = .centerY
        body.spacing = Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        let content = contentView!
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // Same height with or without buttons, so the map below doesn't shift when they come and go.
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: Spacing.xl),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ banner: Banner?, working: Bool) {
        shown = banner
        guard let banner else {
            isHidden = true
            spinner.stopAnimation(nil)
            return
        }
        isHidden = false
        let tint: NSColor
        switch banner.tone {
        case .neutral:
            tint = .systemGreen
            fillColor = .clear
        case .progress:
            tint = .secondaryLabelColor
            fillColor = NSColor.labelColor.withAlphaComponent(0.04)
        case .caution:
            tint = .systemOrange
            fillColor = NSColor.systemOrange.withAlphaComponent(0.10)
        }
        icon.image = NSImage(systemSymbolName: banner.symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.isHidden = working
        if working {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        if titleLabel.stringValue != banner.title { titleLabel.stringValue = banner.title }
        if detailLabel.stringValue != banner.detail { detailLabel.stringValue = banner.detail }
        detailLabel.isHidden = banner.detail.isEmpty
        if shownActions != banner.actions { showButtons(for: banner.actions) }
        updateLayout()
        let spoken = banner.detail.isEmpty ? banner.title : "\(banner.title). \(banner.detail)"
        toolTip = spoken
        setAccessibilityLabel(spoken)
    }

    override func layout() {
        updateLayout()
        super.layout()
    }

    private func updateLayout() {
        guard let shown, bounds.width > 0 else { return }
        let width = max(1, bounds.width - 2 * contentViewMargins.width - Self.iconSize - Spacing.s)
        func textWidth(_ label: NSTextField) -> CGFloat {
            ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width) + Spacing.s
        }
        // Leave room for the scan verb and ellipsis. The scope name can yield to the progress and unread counts.
        let titleWidth =
            shown.kind == .scanning
            ? min(Self.minimumScanTitleWidth, textWidth(titleLabel)) : textWidth(titleLabel)
        let detailWidth = detailLabel.isHidden ? 0 : Spacing.s + textWidth(detailLabel)
        let actionWidth = buttons.isHidden ? 0 : 2 * Spacing.s + buttons.fittingSize.width
        let stacked = titleWidth + detailWidth + actionWidth > width
        let wrapsTitle = stacked && shown.kind != .scanning
        if (body.orientation == .vertical) != stacked {
            row.alignment = stacked ? .top : .centerY
            body.orientation = stacked ? .vertical : .horizontal
            body.alignment = stacked ? .leading : .centerY
            text.orientation = stacked ? .vertical : .horizontal
            text.alignment = stacked ? .leading : .firstBaseline
            spacer.isHidden = stacked
        }
        configureWrapping(titleLabel, width: wrapsTitle ? width : 0)
        configureWrapping(detailLabel, width: stacked ? width : 0)
    }

    private func configureWrapping(_ label: NSTextField, width: CGFloat) {
        guard label.preferredMaxLayoutWidth != width else { return }
        label.maximumNumberOfLines = width > 0 ? 0 : 1
        label.lineBreakMode = width > 0 ? .byWordWrapping : .byTruncatingTail
        label.preferredMaxLayoutWidth = width
        label.invalidateIntrinsicContentSize()
    }

    private func showButtons(for actions: [BannerAction]) {
        shownActions = actions
        buttons.isHidden = actions.isEmpty
        buttons.arrangedSubviews.forEach {
            buttons.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for action in actions {
            let button = NSButton(title: Self.label(action), target: self, action: #selector(tapped(_:)))
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = Typography.secondary
            button.tag = Self.tag(action)
            button.setAccessibilityLabel(Self.label(action))
            if action == .privacySettings { button.toolTip = ProductCopy.BannerButtons.privacySettingsHelp }
            buttons.addArrangedSubview(button)
        }
    }

    private static let actionsByTag: [BannerAction] = [.stop, .coverageDetails, .rescan, .privacySettings]

    private static func label(_ action: BannerAction) -> String {
        switch action {
        case .stop: ProductCopy.BannerButtons.stop
        case .coverageDetails: ProductCopy.BannerButtons.scanDetails
        case .rescan: ProductCopy.BannerButtons.rescan
        case .privacySettings: ProductCopy.BannerButtons.privacySettings
        }
    }

    private static func tag(_ action: BannerAction) -> Int { actionsByTag.firstIndex(of: action)! }

    @objc private func tapped(_ sender: NSButton) {
        onAction?(Self.actionsByTag[sender.tag])
    }
}
