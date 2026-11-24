import AppKit
import SpacewiseAppModel
import SpacewiseCore

/// The main window's content: it lays out the parts, hands each its slice of the screen state, and keeps one
/// selection in step across the list, the map and the inspector. The parts own their own views and copy.
@MainActor final class MainViewController: NSViewController {
    weak var app: AppDelegate?
    private(set) var state = ScreenState()
    /// The selected scan node. It can be deeper than the listed rows when it was picked in the map.
    private(set) var selectedNodeID: Int?
    /// The folder whose summed group of small items is selected in the map (a group is never a node).
    private(set) var selectedAggregateFolder: Int?
    var inspectorVisible: Bool { inspectorOverride ?? (view.bounds.width >= WindowLayout.inspectorWidth) }
    var treemapModel: TreemapModel? { state.treemap?.model }
    var treemapEngaged: Bool { treemapView.isEngaged || selectedNodeID != nil || selectedAggregateFolder != nil }
    var listCollapsed: Bool { splitController.listCollapsed }
    var scanButton: NSButton { readyView.scanButton }
    var treemapView: TreemapView { mapPanel.treemapView }
    var typeList: FileTypeListView { mapPanel.typeList }
    /// The one file type highlighted on the map; the type list and the map both show it.
    private(set) var typeHighlight = TypeHighlight()

    /// The one status line above the map (StatusArea decides what it says, and whether it shows at all).
    private let statusLine = BannerView()
    private let header = ScopeHeaderView()
    private let readyView = ReadyView()
    private let results = NSStackView()
    private let mapPanel = StorageMapPanel()
    private let list = ResultsListView()
    private lazy var splitController = ResultsSplitController(map: mapPanel, list: list)
    private let inspector = InspectorView()
    private let footer = FooterBar()
    private var syncingSelection = false
    private var inspectorOverride: Bool?
    private var lastSource: RowSource?

    override func loadView() {
        let root = NSView()
        view = root
        configureResults()
        let sections: [NSView] = [statusLine, header, readyView, results, footer]
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.s
        stack.edgeInsets = NSEdgeInsets(top: Spacing.m, left: Spacing.l, bottom: Spacing.m, right: Spacing.l)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for item in sections {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Spacing.l).isActive = true
        }
        results.setContentHuggingPriority(.defaultLow, for: .vertical)
        readyView.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: WindowLayout.minimumContentSize.width).isActive = true
        root.heightAnchor.constraint(greaterThanOrEqualToConstant: WindowLayout.minimumContentSize.height).isActive =
            true
    }

    /// The map over the list in a split, with the inspector beside them.
    private func configureResults() {
        inspector.translatesAutoresizingMaskIntoConstraints = false
        inspector.widthAnchor.constraint(equalToConstant: InspectorView.width).isActive = true
        configureMap()
        let split = splitController.split
        splitController.onListCollapsedChange = { [weak self] collapsed in
            guard let self else { return }
            mapPanel.showListCollapsed(collapsed)
            if collapsed, let window = view.window, window.firstResponder === list.table {
                window.makeFirstResponder(mapPanel.listToggle)
            }
            list.table.isListCollapsed = collapsed
        }
        inspector.setContentHuggingPriority(NSLayoutConstraint.Priority(750), for: .horizontal)
        results.setViews([split, inspector], in: .leading)
        results.orientation = .horizontal
        results.spacing = Spacing.s
        results.alignment = .top
        results.distribution = .fill
        split.heightAnchor.constraint(equalTo: results.heightAnchor).isActive = true
        inspector.heightAnchor.constraint(equalTo: results.heightAnchor).isActive = true
        split.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true

        list.table.doubleAction = #selector(AppDelegate.drill)
        list.table.onReturn = { [weak self] in self?.app?.drill() }
        list.table.onCopy = { [weak self] in self?.app?.copyPath() }
        list.table.canCopy = { [weak self] in self?.app?.canCopyPath ?? false }
        list.table.onSpace = { [weak self] in self?.app?.toggleQuickLook() }
        list.table.rowMenu = { [weak self] index in self?.rowMenu(at: index) }
        list.onSortChange = { [weak self] in self?.app?.listSortDidChange($0) }
        list.onSelectionChange = { [weak self] in self?.listSelectionDidChange() }
        header.onOpenScope = { [weak self] in self?.app?.openScope($0) }
    }

    private func configureMap() {
        mapPanel.onToggleList = { [weak self] in self?.toggleList() }
        mapPanel.onZoomOut = { [weak self] in self?.app?.up() }
        mapPanel.onApplyUpdate = { [weak self] in self?.app?.applyPendingTreemap() }
        treemapView.onSelect = { [weak self] in self?.treemapSelect($0) }
        treemapView.onActivate = { [weak self] in self?.treemapActivate($0) }
        treemapView.onHover = { [weak self] _ in
            self?.updateReadout()
            self?.app?.treemapEngagementMayHaveEnded()
        }
        treemapView.cardProvider = { [weak self] in self?.card(for: $0) }
        treemapView.contextMenu = { [weak self] in self?.menu(for: $0) }
        treemapView.canCopy = { [weak self] in self?.app?.canCopyPath ?? false }
        treemapView.onCopy = { [weak self] in self?.app?.copyPath() }
        treemapView.onCancel = { [weak self] in self?.treemapCancel() }
        typeList.onChoose = { [weak self] in self?.chooseType($0) }
    }

    func connectActions() {
        readyView.scanButton.target = app
        readyView.scanButton.action = #selector(AppDelegate.scanInternal)
        readyView.folderButton.target = app
        readyView.folderButton.action = #selector(AppDelegate.scanFolder)
        footer.previousButton.target = app
        footer.previousButton.action = #selector(AppDelegate.previousPage)
        footer.nextButton.target = app
        footer.nextButton.action = #selector(AppDelegate.nextPage)
        statusLine.onAction = { [weak self] in self?.perform($0) }
        inspector.onCoverage = { [weak self] in self?.app?.showCoverage() }
        inspector.onCopy = { [weak self] in self?.app?.copyPath() }
        inspector.onReveal = { [weak self] in self?.app?.showInFinder() }
    }

    private func perform(_ action: BannerAction) {
        switch action {
        case .stop: app?.cancel()
        case .coverageDetails: app?.showCoverage()
        case .rescan: app?.rescan()
        case .privacySettings:
            if let window = view.window { Dialogs.openFullDiskAccessSettings(on: window) }
        }
    }

    // MARK: Rendering

    func render(_ new: ScreenState) {
        let previous = state
        state = new
        let itemCount = new.itemCount
        list.content = ListContent(
            source: new.source, provisional: new.provisional,
            scopeAllocated: new.summary?.allocatedBytes ?? 0,
            itemCount: { node in itemCount?(node.id) })
        let ready = new.phase == .ready
        // A first responder that is hidden hands focus to the next view in the key loop, which is the toolbar's filter
        // field. Give it to the window instead before the results hide.
        if ready, !results.isHidden, let window = view.window, let focused = window.firstResponder as? NSView,
            focused.isDescendant(of: results)
        {
            window.makeFirstResponder(nil)
        }
        readyView.isHidden = !ready
        results.isHidden = ready
        header.isHidden = ready
        // The footer holds only the page buttons, so it shows only when there is more than one page.
        footer.isHidden = ready || !new.canPage
        let working = new.status.map { [.scanning, .stopping, .movingToTrash].contains($0.kind) } ?? false
        statusLine.apply(new.status, working: working)
        if ready {
            readyView.showCapacity(DiskCapacity(new.volume))
            return
        }
        header.render(new)
        let changedSource = new.source !== lastSource
        lastSource = new.source
        if let screen = new.treemap {
            // Within one scan a missing map is the next one being built (a zoom): keep the picture to zoom from.
            let continues = MapContinuity.continues(from: previous.phase, to: new.phase)
            mapPanel.render(
                screen, continuesPrevious: continues,
                holdingPrevious: continues && previous.treemap?.model != nil
            ) {
                syncTreemapSelection()
                keepTypeHighlightIfShown()
            }
        }
        if changedSource {
            list.table.reloadData()
            selectTableRowForSelection()
            if previous.offset != new.offset || previous.summary?.parent != new.summary?.parent {
                list.table.scrollRowToVisible(0)
            }
        }
        list.showEmptyState(new.empty, rowCount: new.source?.count ?? 0)
        updateInspector()
        updateReadout()
        footer.render(new)
        splitController.applyAdaptive(state, showing: !results.isHidden)
        placeDefaultFocus(replacingCurrent: false)
    }

    /// Keyboard focus goes to the list when it shows rows, and otherwise to the window itself, never to the toolbar:
    /// left alone, AppKit gives a new window's focus to the first view in its key loop, the filter field. With
    /// `replacingCurrent` false (every render) focus moves only when nothing has it, so it reaches the list when results
    /// first appear without taking it from wherever the person put it.
    func placeDefaultFocus(replacingCurrent: Bool) {
        guard let window = view.window else { return }
        let unfocused = window.firstResponder == nil || window.firstResponder === window
        guard replacingCurrent || unfocused else { return }
        let listShowsRows = !results.isHidden && !splitController.listCollapsed && (state.source?.count ?? 0) > 0
        if listShowsRows {
            window.makeFirstResponder(list.table)
        } else if !unfocused {
            window.makeFirstResponder(nil)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Wide windows show the inspector by default; narrower ones collapse it (the map's header still describes the
        // selected tile) until toggled.
        if inspector.isHidden == inspectorVisible && state.phase != .ready { inspector.isHidden = !inspectorVisible }
        splitController.applyAdaptive(state, showing: !results.isHidden)
    }

    // MARK: Selection

    /// The real selected item, which can be deeper than the listed rows when it was picked in the map.
    func selectedRow() -> ScopeRow? { selectedNodeID.flatMap(row(forNode:)) }

    func row(forNode id: Int) -> ScopeRow? {
        if let row = state.rowForNode?(id) { return row }
        if let source = state.source, let index = source.index(ofNode: id) { return source.row(at: index) }
        return nil
    }

    // MARK: List

    var listTable: NSTableView { list.table }
    /// The sort the list's headers show (restored with the table's saved layout).
    var listSort: ListSort? { list.currentSort }

    func focusListedRows() {
        guard !state.isPreparingRows, !results.isHidden, (state.source?.count ?? 0) > 0,
            let window = view.window
        else { return }
        if listCollapsed { toggleList() }
        guard window.makeFirstResponder(list.table), window.firstResponder === list.table else { return }
        if let selected = list.selectedRow, selected.node.id == selectedNodeID {
            list.table.scrollRowToVisible(list.table.selectedRow)
        } else {
            selectFirstListedRow()
            // A nested tile can already have the first row highlighted as its ancestor.
            if selectedNodeID != list.selectedRow?.node.id || selectedAggregateFolder != nil {
                listSelectionDidChange()
            }
        }
    }

    func selectFirstListedRow() {
        guard (state.source?.count ?? 0) > 0 else { return }
        list.table.selectRowIndexes([0], byExtendingSelection: false)
        list.table.scrollRowToVisible(0)
    }

    /// The list's row menu, for the row the secondary click has just selected.
    private func rowMenu(at index: Int) -> NSMenu? {
        guard let app, let row = list.content.source?.row(at: index) else { return nil }
        // A nested map tile can leave its listed ancestor highlighted without selecting that ancestor.
        if selectedNodeID != row.node.id { listSelectionDidChange() }
        return ItemActions.rowMenu(
            target: app, node: row.node.id, canOpenFolder: ScopeNavigation.canOpen(row.node),
            open: app.selectionOpenBehavior)
    }

    func clickedOrSelectedRow() -> ScopeRow? {
        if list.hasClickedRow { return list.clickedRow }
        return selectedRow()
    }

    private func listSelectionDidChange() {
        guard !syncingSelection else { return }
        selectedNodeID = list.selectedRow?.node.id
        selectedAggregateFolder = nil
        syncTreemapSelection()
        updateInspector()
        updateReadout()
        app?.selectionDidChange()
    }

    func clearSelection() {
        syncingSelection = true
        list.table.deselectAll(nil)
        syncingSelection = false
        selectedNodeID = nil
        selectedAggregateFolder = nil
        treemapView.selectedTile = nil
        updateInspector()
        updateReadout()
    }

    /// The listed row that stands for `node`: the ancestor (or the node itself) directly under the scope.
    private func listNode(for node: Int) -> Int? {
        let parentOf = state.parentOf
        return ScopeNavigation.listedAncestor(of: node, under: state.summary?.parent) { parentOf?($0) }
    }

    /// The summed-group tile inside `folder`'s tile, when the map drew one.
    private func aggregateTile(forFolder folder: Int, in model: TreemapModel) -> Int? {
        let parent = folder == model.tiles[0].nodeID ? 0 : model.tileIndex(forNode: folder)
        return parent.flatMap { index in model.tiles[index].children.first { model.tiles[$0].kind == .aggregate } }
    }

    private func selectTableRowForSelection() {
        syncingSelection = true
        defer { syncingSelection = false }
        var listed: Int?
        if let folder = selectedAggregateFolder, let model = treemapModel,
            let tile = aggregateTile(forFolder: folder, in: model)
        {
            listed = model.scopeLevelNode(of: model.tiles[tile].parent)
        } else if let id = selectedNodeID {
            listed = listNode(for: id)
        }
        let shown = list.select(node: listed, scroll: false)
        // A page change drops a selection nothing else on screen can represent.
        if !shown, !state.isPreparingRows, let id = selectedNodeID, treemapModel?.tileIndex(forNode: id) == nil {
            selectedNodeID = nil
        }
    }

    /// Highlights the tile for the selection: its own, or the nearest drawn ancestor (its group when summed).
    func syncTreemapSelection() {
        guard let model = treemapModel else {
            treemapView.selectedTile = nil
            return
        }
        if let folder = selectedAggregateFolder {
            treemapView.selectedTile = aggregateTile(forFolder: folder, in: model)
        } else if let id = selectedNodeID {
            treemapView.selectedTile = model.nearestTile(forNode: id, parentOf: { [state] in state.parentOf?($0) })
        } else {
            treemapView.selectedTile = nil
        }
    }

    // MARK: Inspector

    private func updateInspector() {
        let canCoverage = app?.canShowCoverage ?? false
        if let folder = selectedAggregateFolder, let model = treemapModel,
            let tile = aggregateTile(forFolder: folder, in: model)
        {
            let parent = model.tiles[tile].parent
            let name = model.rows[parent]?.node.name ?? state.summary?.crumbs.last?.name ?? state.scopeTitle
            let fields = TreemapPresentation.aggregateFields(
                tile: tile, in: model, folderName: name,
                folderPath: state.pathFor?(folder))
            let title = TreemapPresentation.detail(tile: tile, in: model)?.title ?? ProductCopy.Inspector.group
            inspector.show(title: title, fields: fields, canReveal: false, canCoverage: canCoverage)
        } else if let row = selectedRow(), let inspect = state.inspect {
            let presentation = RowPresentation(
                row: row, provisional: state.provisional,
                scopeAllocated: state.summary?.allocatedBytes ?? 0)
            let content = inspect(row, presentation)
            inspector.show(
                title: presentation.name, fields: content.fields, notes: content.notes,
                canReveal: content.canReveal, canCoverage: canCoverage)
        } else {
            inspector.showEmpty(canCoverage: canCoverage)
        }
    }

    func showInspectorNotice(_ text: String) { inspector.setNotice(text) }

    func setInspectorVisible(_ visible: Bool) {
        inspectorOverride = visible
        inspector.isHidden = !visible
    }

    // MARK: Map and list split

    func resetSplit() { splitController.reset(state, showing: !results.isHidden) }

    func toggleList() { splitController.toggleList(rowCount: state.total) }

    // MARK: Storage map

    func updateReadout() { mapPanel.updateReadout(model: treemapModel, pathFor: state.pathFor) }

    private func treemapSelect(_ tile: Int?) {
        guard let model = treemapModel, let tile, model.tiles.indices.contains(tile), tile != 0 else {
            clearSelection()
            app?.selectionDidChange()
            app?.treemapEngagementMayHaveEnded()
            return
        }
        let value = model.tiles[tile]
        syncingSelection = true
        defer { syncingSelection = false }
        let listed: Int?
        if value.kind == .aggregate {
            selectedNodeID = nil
            selectedAggregateFolder = model.tiles[value.parent].nodeID
            listed = model.scopeLevelNode(of: value.parent)
        } else {
            selectedNodeID = value.nodeID
            selectedAggregateFolder = nil
            listed = model.scopeLevelNode(of: tile)
        }
        list.select(node: listed, scroll: true)
        treemapView.selectedTile = tile
        updateInspector()
        updateReadout()
        app?.selectionDidChange()
    }

    /// Esc on the map clears the selection and the type highlight together.
    private func treemapCancel() {
        treemapSelect(nil)
        chooseType(nil)
    }

    // MARK: File-type highlight

    /// A type was chosen in the list (nil clears). Choosing the highlighted type again clears it.
    func chooseType(_ category: FileCategory?) {
        if let category {
            typeHighlight.choose(category)
        } else {
            typeHighlight.clear()
        }
        showTypeHighlight()
    }

    private func showTypeHighlight() {
        treemapView.highlightedCategory = typeHighlight.category
        typeList.show(typeHighlight.category)
    }

    /// A new map that no longer has the highlighted type drops the highlight; a missing map (being built) keeps it.
    private func keepTypeHighlightIfShown() {
        guard treemapModel != nil else { return }
        typeHighlight.keep(only: typeList.rows)
        showTypeHighlight()
    }

    /// Double-click or Return on a tile: a file is shown in Finder, a folder is opened.
    private func treemapActivate(_ tile: Int) {
        guard let model = treemapModel, model.tiles.indices.contains(tile), model.tiles[tile].nodeID >= 0 else {
            return
        }
        if model.tiles[tile].kind == .file {
            app?.showInFinder()
        } else {
            app?.drill()
        }
    }

    private func card(for tile: Int) -> HoverCard? {
        guard let model = treemapModel else { return nil }
        return StorageMapPanel.card(for: tile, in: model, pathFor: state.pathFor)
    }

    /// The map's context menu: the list's row menu for the tile the secondary click has just selected, with the same
    /// Open rule. A group of smaller items is not one item, so it has no menu.
    private func menu(for tile: Int) -> NSMenu? {
        guard let model = treemapModel, model.tiles.indices.contains(tile), let app, let row = selectedRow(),
            model.tiles[tile].nodeID == row.node.id
        else {
            return nil
        }
        return ItemActions.rowMenu(
            target: app, node: row.node.id, canOpenFolder: ScopeNavigation.canOpen(row.node),
            open: app.selectionOpenBehavior, openFolderTitle: ProductCopy.Map.menuZoomIn)
    }
}
