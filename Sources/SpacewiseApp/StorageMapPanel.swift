import AppKit
import SpacewiseAppModel
import SpacewiseCore

/// The storage map panel above the list: a header row of controls, and the map with its file-type list beside it. The
/// header's line beside the title says what the map shows, or, while the pointer is on a tile or one is selected, that
/// tile: the line is always there, so pointing at the map never moves the layout. It shows what it is given; selection,
/// navigation and the type highlight belong to its owner.
@MainActor final class StorageMapPanel: NSView {
    let treemapView = TreemapView()
    let typeList = FileTypeListView()
    /// Zoom Out, the update chip and the list toggle were pressed.
    var onZoomOut: (() -> Void)?
    var onApplyUpdate: (() -> Void)?
    var onToggleList: (() -> Void)?
    private let title = NSTextField(labelWithString: ProductCopy.Map.title)
    /// What the map shows, or the hovered or selected tile.
    private let summary = NSTextField(labelWithString: "")
    /// What the map shows ("4,493 items drawn"), shown in `summary` when no tile is pointed at or selected.
    private var mapSummary = ""
    private let messageTitle = NSTextField(labelWithString: "")
    private let messageDetail = NSTextField(wrappingLabelWithString: "")
    private let message = NSStackView()
    private let zoomOutButton = NSButton()
    private let updateChip = NSButton()
    private let infoButton = NSButton()
    let listToggle = NSButton()
    private let typesToggle = NSButton()
    private var shownRevision = -1
    /// The message for the last screen, shown once the map has nothing (not even a held picture) to draw.
    private var shownMessage: EmptyScope?
    /// The person's choice for the type list; nil follows the width (hidden at the minimum window size).
    private var typeListPreference: Bool?
    private var mapToTypeList: NSLayoutConstraint!
    private var mapToEdge: NSLayoutConstraint!
    /// Below this panel width the type list hides unless the person shows it, so the map keeps its width.
    static let typeListMinimumPanelWidth: CGFloat = 900
    /// The model of the last screen rendered, which the info popover describes.
    private var shownModel: TreemapModel?
    /// The map never gets shorter than this.
    static let minimumMapHeight: CGFloat = 110

    override init(frame: NSRect) {
        super.init(frame: frame)
        configureLabels()
        configureControls()
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [
            title, summary, spacer, updateChip, zoomOutButton, listToggle, typesToggle,
            infoButton,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Spacing.s
        for item in [header, treemapView, typeList, message] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        mapToTypeList = treemapView.trailingAnchor.constraint(equalTo: typeList.leadingAnchor, constant: -Spacing.m)
        mapToEdge = treemapView.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            treemapView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Spacing.s),
            treemapView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapToTypeList,
            typeList.topAnchor.constraint(equalTo: treemapView.topAnchor),
            typeList.bottomAnchor.constraint(equalTo: treemapView.bottomAnchor),
            typeList.trailingAnchor.constraint(equalTo: trailingAnchor),
            typeList.widthAnchor.constraint(equalToConstant: FileTypeListView.width),
            treemapView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.s),
            message.centerXAnchor.constraint(equalTo: treemapView.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: treemapView.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            treemapView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumMapHeight),
        ])
        treemapView.onHoldEnded = { [weak self] in self?.showMessage() }
        setAccessibilityRole(.group)
        setAccessibilityLabel(ProductCopy.Map.title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configureLabels() {
        title.font = Typography.heading
        summary.font = Typography.numericSecondary
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingMiddle
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.setAccessibilityLabel(ProductCopy.Map.readoutAccessibility)
        messageTitle.font = Typography.heading
        messageTitle.alignment = .center
        messageDetail.font = Typography.secondary
        messageDetail.textColor = .secondaryLabelColor
        messageDetail.alignment = .center
        messageDetail.preferredMaxLayoutWidth = 360
        message.setViews([messageTitle, messageDetail], in: .center)
        message.orientation = .vertical
        message.spacing = Spacing.xs
        message.setAccessibilityElement(true)
        message.setAccessibilityRole(.group)
    }

    private func configureControls() {
        let copy = ProductCopy.Map.self
        zoomOutButton.title = copy.zoomOut
        zoomOutButton.bezelStyle = .accessoryBarAction
        zoomOutButton.controlSize = .small
        zoomOutButton.image = NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: nil)
        zoomOutButton.imagePosition = .imageLeading
        zoomOutButton.toolTip = copy.zoomOutTip
        zoomOutButton.setAccessibilityLabel(copy.zoomOutAccessibility)
        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOutPressed)
        updateChip.title = copy.update
        updateChip.bezelStyle = .accessoryBarAction
        updateChip.controlSize = .small
        updateChip.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        updateChip.imagePosition = .imageLeading
        updateChip.toolTip = copy.updateTip
        updateChip.target = self
        updateChip.action = #selector(updatePressed)
        updateChip.isHidden = true
        infoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: copy.infoAccessibility)
        infoButton.isBordered = false
        infoButton.imagePosition = .imageOnly
        infoButton.contentTintColor = .secondaryLabelColor
        infoButton.toolTip = copy.infoTip
        infoButton.target = self
        infoButton.action = #selector(showInfo(_:))
        listToggle.isBordered = false
        listToggle.imagePosition = .imageOnly
        listToggle.contentTintColor = .secondaryLabelColor
        listToggle.target = self
        listToggle.action = #selector(listTogglePressed)
        showListCollapsed(false)
        typesToggle.isBordered = false
        typesToggle.imagePosition = .imageOnly
        typesToggle.contentTintColor = .secondaryLabelColor
        typesToggle.target = self
        typesToggle.action = #selector(typesTogglePressed)
        showTypeListToggle()
    }

    // MARK: File-type list

    /// Whether the type list is beside the map: the person's choice, or by width when they have not chosen.
    var typeListVisible: Bool {
        guard !typeList.rows.isEmpty else { return false }
        return typeListPreference ?? (bounds.width >= Self.typeListMinimumPanelWidth)
    }

    @objc private func typesTogglePressed() {
        typeListPreference = !(typeListPreference ?? (bounds.width >= Self.typeListMinimumPanelWidth))
        applyTypeListVisibility()
        if typeListVisible { window?.makeFirstResponder(typeList.table) }
    }

    private func applyTypeListVisibility() {
        let visible = typeListVisible
        if typeList.isHidden == !visible, mapToTypeList.isActive == visible { return }
        typeList.isHidden = !visible
        // A hidden type list leaves the key view loop, so Tab goes from the map straight to the item list.
        if !visible, window?.firstResponder === typeList.table { window?.makeFirstResponder(treemapView) }
        mapToEdge.isActive = !visible
        mapToTypeList.isActive = visible
        showTypeListToggle()
    }

    private func showTypeListToggle() {
        let shown = typeListPreference ?? (bounds.width >= Self.typeListMinimumPanelWidth)
        let label = shown ? ProductCopy.FileTypes.hide : ProductCopy.FileTypes.show
        typesToggle.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: label)
        typesToggle.toolTip = ProductCopy.FileTypes.toggleTip(label)
        typesToggle.setAccessibilityLabel(label)
        typesToggle.isHidden = typeList.rows.isEmpty
    }

    override func layout() {
        super.layout()
        applyTypeListVisibility()
    }

    /// The list toggle shows the action it will take.
    func showListCollapsed(_ collapsed: Bool) {
        let label = collapsed ? ProductCopy.Map.showList : ProductCopy.Map.hideList
        let symbol = collapsed ? "list.bullet.below.rectangle" : "rectangle.bottomhalf.inset.filled"
        listToggle.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        listToggle.toolTip = ProductCopy.Map.listToggleTip(label)
        listToggle.setAccessibilityLabel(label)
    }

    /// Applied on every render; the map and type list reload only when the model's revision changes, and
    /// `modelDidChange` runs right after they do. With `holdingPrevious`, a missing model (the next map is being
    /// built after a zoom) keeps the current picture and type list up briefly so the next map can zoom out of it.
    /// Without `continuesPrevious` (a new scan) the next map fades in from empty instead of moving from the old one.
    func render(_ screen: TreemapScreen, continuesPrevious: Bool, holdingPrevious: Bool, modelDidChange: () -> Void) {
        shownModel = screen.model
        zoomOutButton.isEnabled = screen.canZoomOut
        updateChip.isHidden = !screen.pendingUpdate
        if screen.revision != shownRevision {
            shownRevision = screen.revision
            treemapView.setModel(screen.model, continuesPrevious: continuesPrevious, holdingPrevious: holdingPrevious)
            if screen.model != nil || !treemapView.isHolding { typeList.set(FileTypeList.rows(for: screen.model)) }
            applyTypeListVisibility()
            modelDidChange()
        }
        mapSummary = screen.model.map(TreemapPresentation.summary) ?? ""
        if treemapView.hoverTile == nil && treemapView.selectedTile == nil { summary.stringValue = mapSummary }
        shownMessage = screen.model.map { $0.isEmpty } ?? true ? screen.message : nil
        showMessage()
        treemapView.setAccessibilityEnabled(!(screen.model?.isEmpty ?? true))
    }

    /// The message stays hidden while the previous picture is held, so the map does not flash "Building".
    private func showMessage() {
        guard let shown = shownMessage, !treemapView.isHolding else {
            message.isHidden = true
            return
        }
        if treemapView.model == nil, !typeList.rows.isEmpty {
            typeList.set([])
            applyTypeListVisibility()
        }
        message.isHidden = false
        messageTitle.stringValue = shown.title
        messageDetail.stringValue = shown.detail
        message.setAccessibilityLabel("\(shown.title). \(shown.detail)")
    }

    /// The line beside the title: the hovered or selected tile, else what the map shows. How to use the map is in the
    /// info popover.
    func updateReadout(model: TreemapModel?, pathFor: ((Int) -> String?)?) {
        guard let model, !model.isEmpty, let tile = treemapView.hoverTile ?? treemapView.selectedTile,
            model.tiles.indices.contains(tile)
        else {
            summary.stringValue = mapSummary
            return
        }
        let node = model.tiles[tile].nodeID
        summary.stringValue = TreemapPresentation.readout(tile: tile, in: model, path: node >= 0 ? pathFor?(node) : nil)
    }

    /// The hover card for a tile: kind and size, share and type, then any managed or partial caveat and the path.
    static func card(for tile: Int, in model: TreemapModel, pathFor: ((Int) -> String?)?) -> HoverCard? {
        guard let detail = TreemapPresentation.detail(tile: tile, in: model) else { return nil }
        let copy = ProductCopy.Map.self
        var lines = [copy.cardKind(detail.kind, size: detail.size.text)]
        if let share = detail.share {
            lines.append(copy.cardShareLine(copy.cardShare(share), category: detail.category))
        } else {
            lines.append(detail.category)
        }
        if model.tiles[tile].managed { lines.append(copy.cardManaged) }
        if model.tiles[tile].partial || model.provisional {
            lines.append(model.provisional ? copy.cardProvisional : copy.cardPartial)
        }
        let node = model.tiles[tile].nodeID
        return HoverCard(title: detail.title, lines: lines, path: node >= 0 ? pathFor?(node) : nil)
    }

    @objc private func listTogglePressed() { onToggleList?() }
    @objc private func zoomOutPressed() { onZoomOut?() }
    @objc private func updatePressed() { onApplyUpdate?() }

    /// How to read the map, in a popover from the info button. The model adds what this particular map leaves out.
    @objc private func showInfo(_ sender: NSButton) {
        let text = (shownModel.map { TreemapPresentation.disclosure($0) + "\n\n" } ?? "") + ProductCopy.Map.howToRead
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Typography.secondary
        label.preferredMaxLayoutWidth = 340
        let controller = NSViewController()
        let holder = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Spacing.l),
            label.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -Spacing.l),
            label.topAnchor.constraint(equalTo: holder.topAnchor, constant: Spacing.m),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -Spacing.m),
            label.widthAnchor.constraint(equalToConstant: 340),
        ])
        controller.view = holder
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
}
