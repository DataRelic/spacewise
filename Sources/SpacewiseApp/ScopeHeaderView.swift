import AppKit
import SpacewiseAppModel
import SpacewiseCore

/// The scope header above the results: the breadcrumb path, with the scope's totals on the same row. The totals
/// appear only here; the map header and the footer don't repeat them.
final class ScopeHeaderView: NSStackView {
    /// A breadcrumb was chosen: the folder to open, or nil for the top level.
    var onOpenScope: ((Int?) -> Void)?
    private let crumbBar = NSStackView()
    private let metrics = NSStackView()
    private let allocatedMetric = MetricView()
    private let logicalMetric = MetricView()
    private let itemsMetric = MetricView()
    private let matchesMetric = MetricView()
    private var crumbSignature = ""
    private var hiddenCrumbs: [Crumb] = []
    /// One step of the path: its name and the folder it opens (nil for the top level).
    private struct Crumb: Equatable {
        let title: String
        let id: Int?
    }
    /// What the bar shows in each place: a step of the path, or the button standing for the steps it hides. Decided by
    /// position, never by text, so a folder named "…" is still a folder.
    private enum Slot {
        case crumb(Crumb)
        case hidden
    }
    /// Paths longer than this collapse their middle into a menu.
    private static let maximumCrumbs = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        crumbBar.orientation = .horizontal
        crumbBar.spacing = Spacing.xs
        crumbBar.alignment = .centerY
        crumbBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        crumbBar.setAccessibilityLabel(ProductCopy.Header.location)
        crumbBar.setAccessibilityRole(.group)
        metrics.setViews([allocatedMetric, logicalMetric, itemsMetric, matchesMetric], in: .leading)
        metrics.orientation = .horizontal
        metrics.spacing = Spacing.l
        metrics.alignment = .firstBaseline
        metrics.setContentCompressionResistancePriority(.required, for: .horizontal)
        metrics.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        setViews([crumbBar, spacer, metrics], in: .leading)
        orientation = .horizontal
        alignment = .centerY
        spacing = Spacing.l
        itemsMetric.toolTip = ProductCopy.Header.itemsHelp
        itemsMetric.setAccessibilityHelp(ProductCopy.Header.itemsHelp)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func render(_ state: ScreenState) {
        updateCrumbs(state)
        metrics.isHidden = state.summary == nil
        guard let summary = state.summary else { return }
        let head = ScopeHeaderPresentation(
            summary: summary, provisional: state.provisional, total: state.total)
        let copy = ProductCopy.Header.self
        allocatedMetric.set(
            caption: state.provisional ? copy.allocatedSoFar : copy.allocated, value: head.allocated.text,
            tone: head.allocated.kind)
        logicalMetric.set(
            caption: state.provisional ? copy.logicalSoFar : copy.logical, value: head.logical.text,
            tone: head.logical.kind)
        itemsMetric.set(caption: state.provisional ? copy.itemsSoFar : copy.items, value: head.itemsText, tone: .exact)
        matchesMetric.isHidden = !state.isFiltering || state.canPage || state.source == nil
        matchesMetric.set(
            caption: state.provisional ? copy.matchesSoFar : copy.matches,
            value: SizeFormat.count(UInt64(state.source?.count ?? 0)), tone: .exact)
    }

    // MARK: Breadcrumbs

    private func updateCrumbs(_ state: ScreenState) {
        var entries: [Crumb] = []
        if !state.isFolderScope { entries.append(Crumb(title: state.scopeTitle, id: nil)) }
        for crumb in state.summary?.crumbs ?? [] { entries.append(Crumb(title: crumb.name, id: crumb.id)) }
        let signature = entries.map { "\($0.title)|\($0.id.map(String.init) ?? "-")" }.joined(separator: "/")
        guard signature != crumbSignature else { return }
        crumbSignature = signature
        crumbBar.arrangedSubviews.forEach {
            crumbBar.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        var shown = entries.map(Slot.crumb)
        hiddenCrumbs = []
        if entries.count > Self.maximumCrumbs {
            hiddenCrumbs = Array(entries[1..<(entries.count - 3)])
            shown = [.crumb(entries[0]), .hidden] + entries.suffix(3).map(Slot.crumb)
        }
        for (offset, slot) in shown.enumerated() {
            if offset > 0 { crumbBar.addArrangedSubview(chevron()) }
            let current = offset == shown.count - 1
            guard case .crumb(let entry) = slot else {
                let more = NSButton(
                    title: ProductCopy.Header.hiddenCrumbs, target: self,
                    action: #selector(showHiddenCrumbs(_:)))
                more.isBordered = false
                more.setAccessibilityLabel(ProductCopy.Header.hiddenCrumbsAccessibility)
                crumbBar.addArrangedSubview(more)
                continue
            }
            if current {
                let label = NSTextField(labelWithString: entry.title)
                label.font = Typography.title
                label.lineBreakMode = .byTruncatingMiddle
                label.setAccessibilityLabel(ProductCopy.Header.currentFolder(entry.title))
                crumbBar.addArrangedSubview(label)
            } else {
                let button = NSButton(title: entry.title, target: self, action: #selector(crumbClicked(_:)))
                button.isBordered = false
                button.tag = entry.id ?? -1
                button.font = Typography.body
                button.contentTintColor = .controlAccentColor
                button.lineBreakMode = .byTruncatingMiddle
                button.setAccessibilityLabel(ProductCopy.Header.goTo(entry.title))
                crumbBar.addArrangedSubview(button)
            }
        }
    }

    private func chevron() -> NSView {
        let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage()
        let chevron = NSImageView(image: image)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Typography.caption.pointSize, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        return chevron
    }

    @objc private func crumbClicked(_ sender: NSButton) { onOpenScope?(sender.tag < 0 ? nil : sender.tag) }

    @objc private func showHiddenCrumbs(_ sender: NSButton) {
        let menu = NSMenu()
        for (index, entry) in hiddenCrumbs.enumerated() {
            let item = NSMenuItem(title: entry.title, action: #selector(hiddenCrumbChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func hiddenCrumbChosen(_ sender: NSMenuItem) { onOpenScope?(hiddenCrumbs[sender.tag].id) }
}

/// One total in the scope header: a caption and its value on one line. Lower bounds and unknowns read in secondary ink.
final class MetricView: NSStackView {
    private let caption = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        caption.font = Typography.secondary
        caption.textColor = .secondaryLabelColor
        value.font = Typography.numericBodyEmphasis
        value.lineBreakMode = .byTruncatingTail
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = Spacing.xs
        setViews([caption, value], in: .leading)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A nil caption shows the value alone, as a quiet note.
    func set(caption text: String?, value string: String, tone: SizeText.Kind) {
        caption.isHidden = text == nil
        caption.stringValue = text ?? ""
        value.stringValue = string
        value.textColor = (tone == .lowerBound || tone == .unknown) ? .secondaryLabelColor : .labelColor
        setAccessibilityLabel(text.map { "\($0): \(string)" } ?? string)
    }
}
