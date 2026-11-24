import AppKit
import SpacewiseAppModel
import SpacewiseCore

/// Native storage map. Layout and cushion raster are computed off the main actor (`TreemapRenderer`); this view only
/// blits the finished image and draws cheap overlays (`TreemapDrawing`): labels, hover, selection, type dimming and the
/// detail card. Moving between maps (zooming, live checkpoints) animates the two finished bitmaps
/// (`TreemapTransitionView`); nothing is re-rendered per frame. It never touches the filesystem and holds only the
/// bounded `TreemapModel` it is given.
@MainActor final class TreemapView: NSView, NSUserInterfaceValidations {
    typealias RenderMap = @Sendable (TreemapModel, CGSize, CGFloat, Bool, Bool) async -> RenderedMap?

    // Callbacks into the controller. Selection and the type highlight live there; this view only displays them.
    var onSelect: ((Int?) -> Void)?
    var onActivate: ((Int) -> Void)?
    var onHover: ((Int?) -> Void)?
    /// Esc on the map: clear the selection and the type highlight.
    var onCancel: (() -> Void)?
    var contextMenu: ((Int) -> NSMenu?)?
    var cardProvider: ((Int) -> HoverCard?)?
    var onCopy: (() -> Void)?
    var canCopy: () -> Bool = { false }
    /// The previous map stopped being shown because no new one arrived in time (see `setModel(_:continuesPrevious:holdingPrevious:)`).
    var onHoldEnded: (() -> Void)?

    /// The model last given. Overlays and hit testing use it only once a render of it is on screen.
    private(set) var model: TreemapModel?
    private struct RenderRequest: Equatable {
        let generation: Int
        let size: CGSize
        let scale: CGFloat
        let dark: Bool
        let edges: Bool
    }
    private struct PendingRender {
        let request: RenderRequest
        let readyAt: ContinuousClock.Instant?
    }

    /// A finished render and the overlays planned for its source geometry.
    private struct Frame {
        let request: RenderRequest
        let model: TreemapModel
        let layout: TreemapLayout
        let image: CGImage
        let picture: NSImage
        let labels: [TreemapLabel]

        /// The raster and layout share a zero-based source. AppKit draws the raster into the entire view bounds.
        func transform(to bounds: CGRect) -> CGAffineTransform {
            CGAffineTransform(
                a: bounds.width / request.size.width, b: 0,
                c: 0, d: bounds.height / request.size.height,
                tx: bounds.minX, ty: bounds.minY)
        }
    }
    private var shown: Frame?
    /// Tile indices are valid only within this model generation.
    private var generation = 0
    private var current: Frame? { shown.flatMap { $0.request.generation == generation ? $0 : nil } }
    /// The source layout of the displayed render, when it matches the model.
    var mapLayout: TreemapLayout? { current?.layout }
    /// True while the previous map stays up waiting for the next one (a zoom whose new map is still being built).
    private(set) var isHolding = false
    private var holdTimer: Timer?
    private let renderMap: RenderMap
    /// The task owns the slot from debounce through renderer exit. A request stays pending until it starts rendering.
    private var renderTask: Task<Void, Never>?
    private var renderingRequest: RenderRequest?
    private var pendingRender: PendingRender?
    private var lastBounds: CGRect?
    private var transition: TreemapTransitionView?
    /// How long the previous map is held while the next one is built before the panel's message replaces it.
    private static let holdSeconds = 0.6

    var selectedTile: Int? {
        didSet {
            guard oldValue != selectedTile else { return }
            invalidate(oldValue)
            invalidate(selectedTile)
            hideKeyboardCard()
            announceSelection()
        }
    }
    private(set) var hoverTile: Int? {
        didSet {
            guard oldValue != hoverTile else { return }
            invalidateWithFolder(oldValue)
            invalidateWithFolder(hoverTile)
            onHover?(hoverTile)
        }
    }
    var highlightedCategory: FileCategory? {
        didSet {
            if oldValue != highlightedCategory { needsDisplay = true }
        }
    }
    var isEngaged: Bool { hoverTile != nil }

    /// The last pointer event and the card's anchor, in screen coordinates so they follow the window geometry.
    private var pointerLocation: CGPoint?
    private var pointerCard: CGPoint? {
        didSet { if oldValue != pointerCard { needsDisplay = true } }
    }
    private var keyboardCard = false
    private var cardTimer: Timer?
    private var tracking: NSTrackingArea?
    private var accessibilityTiles: [TileAccessibilityElement] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(rect: bounds).fill() }

    override convenience init(frame: NSRect) {
        self.init(frame: frame, renderMap: TreemapRenderer.render)
    }

    init(frame: NSRect, renderMap: @escaping RenderMap) {
        self.renderMap = renderMap
        super.init(frame: frame)
        lastBounds = bounds
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(ProductCopy.Map.title)
        setAccessibilityHelp(ProductCopy.Map.accessibilityHelp)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { renderTask?.cancel() }

    // MARK: Model and rendering

    /// Show a new model. With `holdingPrevious`, a nil model (the next map is being built, as after a zoom) keeps the
    /// current picture up for a moment, without overlays or interaction, so the next map can zoom out of it.
    /// Without `continuesPrevious` (a new scan, or results left) the picture is dropped, so the next map fades in rather
    /// than moving from an unrelated one.
    func setModel(_ new: TreemapModel?, continuesPrevious: Bool = true, holdingPrevious: Bool = false) {
        finishTransition()
        if !continuesPrevious { shown = nil }
        model = new
        generation += 1
        // The hover callback can synchronously apply another live model.
        defer { hoverTile = nil }
        pointerLocation = nil
        pointerCard = nil
        hideKeyboardCard()
        cardTimer?.invalidate()
        accessibilityTiles = []
        setAccessibilityValue(nil)
        holdTimer?.invalidate()
        holdTimer = nil
        if new == nil {
            cancelRender()
            if holdingPrevious, shown != nil {
                isHolding = true
                holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdSeconds, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.endHold() }
                }
            } else {
                shown = nil
                isHolding = false
            }
            needsDisplay = true
            return
        }
        isHolding = false
        needsDisplay = true
        updateRender(immediate: true)
    }

    private func endHold() {
        holdTimer = nil
        guard isHolding else { return }
        isHolding = false
        if model == nil { shown = nil }
        needsDisplay = true
        onHoldEnded?()
    }

    override func layout() {
        super.layout()
        updateBounds()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateBounds()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateBounds()
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        updateBounds()
    }

    private func updateBounds() {
        guard lastBounds != bounds else { return }
        lastBounds = bounds
        // End the animation before AppKit resizes its overlay; the retained bitmap then fills the new bounds.
        finishTransition()
        needsDisplay = true
        updateRender(immediate: current == nil)
        updatePointerTarget()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateRender(immediate: true)
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateRender(immediate: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRender(immediate: true)
    }

    /// Increase Contrast adds tile edges to the bitmap; Reduce Transparency and Increase Contrast make overlays opaque.
    @objc private func accessibilityDisplayOptionsDidChange() {
        updateRender(immediate: true)
        needsDisplay = true
    }

    private var desiredRender: RenderRequest? {
        guard model != nil, bounds.width > 4, bounds.height > 4 else { return nil }
        return RenderRequest(
            generation: generation, size: bounds.size,
            scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
            dark: effectiveAppearance.isDarkAqua,
            edges: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }

    private func cancelRender() {
        pendingRender = nil
        renderTask?.cancel()
    }

    private func updateRender(immediate: Bool) {
        guard let request = desiredRender, shown?.request != request else {
            // Returning to the shown size can supersede a pending render even though nothing new needs drawing.
            cancelRender()
            return
        }
        if renderingRequest == request, renderTask?.isCancelled == false { return }
        if let pendingRender, pendingRender.request == request, !immediate || pendingRender.readyAt == nil { return }
        renderTask?.cancel()
        // Measure the warm resize debounce from the request, even when a cancelled worker is still exiting.
        pendingRender = PendingRender(
            request: request, readyAt: immediate ? nil : .now + .milliseconds(90))
        startPendingRender()
    }

    private func startPendingRender() {
        guard renderTask == nil, let pendingRender, let model else { return }
        let request = pendingRender.request
        renderTask = Task { [weak self, renderMap] in
            defer { self?.finishRender() }
            if let readyAt = pendingRender.readyAt, readyAt > .now {
                try? await ContinuousClock().sleep(until: readyAt)
            }
            guard !Task.isCancelled, self != nil else { return }
            self?.pendingRender = nil
            self?.renderingRequest = request
            if let result = await renderMap(model, request.size, request.scale, request.dark, request.edges),
                !Task.isCancelled, let self, self.desiredRender == request
            {
                self.apply(result, model: model, request: request)
            }
        }
    }

    private func finishRender() {
        // A cancelled request owns the worker slot until its renderer returns. Its task stays cancelled even if
        // a later request returns to the same key. Only the newest pending request can take the slot next.
        renderTask = nil
        renderingRequest = nil
        startPendingRender()
    }

    private func apply(_ result: RenderedMap, model: TreemapModel, request: RenderRequest) {
        let previous = shown
        let next = Frame(
            request: request, model: model, layout: result.layout, image: result.image,
            picture: NSImage(cgImage: result.image, size: request.size),
            labels: TreemapLabelPlanner.plan(model: model, layout: result.layout, dark: request.dark))
        shown = next
        isHolding = false
        holdTimer?.invalidate()
        holdTimer = nil
        if previous?.request.generation != request.generation { rebuildAccessibility(for: next) }
        needsDisplay = true
        startTransition(from: previous, to: next)
        updatePointerTarget()
    }

    // MARK: Transitions

    private func startTransition(from previous: Frame?, to next: Frame) {
        finishTransition()
        let kind: TreemapTransition
        if let previous {
            // The old layout was computed for the old size; scale it to the view so a zoom starts where the folder is.
            var oldLayout = previous.layout
            if previous.request.size != next.request.size {
                let sx = next.request.size.width / previous.request.size.width
                let sy = next.request.size.height / previous.request.size.height
                oldLayout = previous.layout.scaled(x: sx, y: sy)
            }
            kind = TreemapTransition.between(
                old: previous.model, oldLayout, new: next.model, next.layout,
                sameModel: previous.request.generation == next.request.generation,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else {
            // The first map after none: new tiles fade in (a cross-fade from the empty backdrop).
            kind = .crossFade
        }
        guard kind != .cut else { return }
        let view = TreemapTransitionView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        transition = view
        view.run(
            kind, outgoing: previous?.image, incoming: next.image,
            backdrop: TreemapPalette.backdrop(dark: next.request.dark).nsColor
        ) { [weak self, weak view] in
            guard let self, let view, self.transition === view else { return }
            self.finishTransition()
        }
    }

    /// Lands any running transition at its end state: the current map, drawn by this view.
    private func finishTransition() {
        guard let view = transition else { return }
        transition = nil
        view.stop()
        view.removeFromSuperview()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDarkAqua
        let backdrop = TreemapPalette.backdrop(dark: dark).nsColor
        NSBezierPath(rect: bounds).setClip()
        backdrop.setFill()
        dirtyRect.intersection(bounds).fill()
        guard let shown else { return }
        NSGraphicsContext.current?.imageInterpolation = shown.request.size == bounds.size ? .none : .high
        shown.picture.draw(
            in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard let current, !bounds.isEmpty else { return }
        let style = TreemapDrawing.Style.current
        let transform = current.transform(to: bounds)
        drawOverlays(current, transform: transform, dirtyRect: dirtyRect, backdrop: backdrop, style: style)

        if let anchor = cardAnchor(in: current, transform: transform), let content = cardProvider?(anchor.tile) {
            TreemapDrawing.card(content, at: anchor.point, in: bounds, style: style)
        }
    }

    private func drawOverlays(
        _ frame: Frame, transform: CGAffineTransform, dirtyRect: CGRect, backdrop: NSColor, style: TreemapDrawing.Style
    ) {
        let model = frame.model
        let layout = frame.layout
        let sourceDirty = dirtyRect.applying(transform.inverted())
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.concatenate(transform)

        if let category = highlightedCategory {
            TreemapDrawing.wash(model, layout, except: category, backdrop: backdrop, style: style, in: sourceDirty)
        }
        if let group = model.tileIndex(forNode: LogicalNamespace.managedGroupID), layout.rects.indices.contains(group) {
            TreemapDrawing.groupFrame(layout.rects[group])
        }
        for label in frame.labels where label.rect.intersects(sourceDirty) {
            // A type highlight hides the names on the tiles it dims, so only the highlighted type reads.
            if let category = highlightedCategory, !label.pill, let tile = label.tile,
                !LegendFocus.matches(model.tiles[tile], category)
            {
                continue
            }
            TreemapDrawing.label(label, style: style)
        }

        if let hover = hoverTile, layout.rects.indices.contains(hover) {
            // The folder that holds the hovered tile, so the structure reads at a glance.
            let folder = model.tiles[hover].parent
            if folder > 0, layout.rects.indices.contains(folder) { TreemapDrawing.folderOutline(layout.rects[folder]) }
            if hover != selectedTile {
                TreemapDrawing.outline(layout.rects[hover], white: 0.95, width: 1.5, shadow: 0.55)
            }
        }
        if let selected = selectedTile, layout.rects.indices.contains(selected) {
            TreemapDrawing.outline(layout.rects[selected], white: 1, width: 2.5, shadow: 0.9)
        }
    }

    private func invalidate(_ tile: Int?) {
        guard let tile, let current, current.layout.rects.indices.contains(tile) else { return }
        setNeedsDisplay(current.layout.rects[tile].insetBy(dx: -4, dy: -4).applying(current.transform(to: bounds)))
    }

    /// A tile and the folder outline drawn around it on hover.
    private func invalidateWithFolder(_ tile: Int?) {
        invalidate(tile)
        guard let tile, let current, current.model.tiles.indices.contains(tile) else { return }
        let folder = current.model.tiles[tile].parent
        if folder > 0 { invalidate(folder) }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// A folder label (pill) stands for its folder: an expanded folder is otherwise covered by its contents, so the pill
    /// is the pointer target for selecting it (click) and zooming into it (double-click). Elsewhere the deepest tile wins.
    func tile(atPoint point: CGPoint) -> Int? {
        guard let current, bounds.contains(point) else { return nil }
        let source = point.applying(current.transform(to: bounds).inverted())
        if let pill = current.labels.last(where: { $0.pill && $0.tile != nil && $0.rect.contains(source) }) {
            return pill.tile
        }
        let hit = current.layout.hit(source, in: current.model)
        return hit == 0 ? nil : hit
    }

    private func tile(at event: NSEvent) -> Int? { tile(atPoint: convert(event.locationInWindow, from: nil)) }

    private func viewPoint(fromScreen point: CGPoint) -> CGPoint? {
        window.map { convert($0.convertPoint(fromScreen: point), from: nil) }
    }

    private func updatePointerTarget() {
        let tile = pointerLocation.flatMap(viewPoint(fromScreen:)).flatMap(tile(atPoint:))
        guard tile != hoverTile else { return }
        pointerCard = nil
        cardTimer?.invalidate()
        hoverTile = tile
    }

    override func mouseMoved(with event: NSEvent) {
        hideKeyboardCard()
        pointerLocation = window?.convertPoint(toScreen: event.locationInWindow)
        updatePointerTarget()
        cardTimer?.invalidate()
        guard hoverTile != nil else { return }
        cardTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerCard = self?.pointerLocation }
        }
    }

    override func mouseExited(with event: NSEvent) {
        pointerLocation = nil
        updatePointerTarget()
    }

    /// The click that activates an inactive window also selects the tile under it. AppKit otherwise discards that click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let current else { return }
        pointerCard = nil
        hideKeyboardCard()
        cardTimer?.invalidate()
        let clicked = tile(at: event)
        if event.clickCount >= 2, let clicked {
            _ = select(clicked, activating: true, generation: current.request.generation)
            return
        }
        // ⌘-click toggles the tile out of the (single-item) selection.
        if event.modifierFlags.contains(.command), clicked == selectedTile {
            onSelect?(nil)
            return
        }
        onSelect?(clicked)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let current, let clicked = tile(at: event) else { return }
        let generation = current.request.generation
        guard select(clicked, activating: false, generation: generation),
            self.current?.request.generation == generation,
            let menu = contextMenu?(clicked)
        else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// The callbacks use indices in the controller's latest model. Selection can synchronously replace that model.
    private func select(_ tile: Int, activating: Bool, generation: Int) -> Bool {
        guard current?.request.generation == generation else { return false }
        onSelect?(tile)
        if activating {
            guard current?.request.generation == generation else { return false }
            onActivate?(tile)
        }
        return true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let current, !bounds.isEmpty else {
            super.keyDown(with: event)
            return
        }
        let model = current.model
        let direction: TreemapLayout.Direction?
        switch event.keyCode {
        case KeyCode.leftArrow: direction = .left
        case KeyCode.rightArrow: direction = .right
        case KeyCode.downArrow: direction = event.modifierFlags.contains(.command) ? nil : .down
        case KeyCode.upArrow: direction = event.modifierFlags.contains(.command) ? nil : .up
        default: direction = nil
        }
        if let direction {
            let transform = current.transform(to: bounds)
            let layout =
                current.request.size == bounds.size
                ? current.layout : current.layout.scaled(x: transform.a, y: transform.d)
            let start = selectedTile ?? hoverTile ?? model.tiles.indices.dropFirst().first { model.tiles[$0].isLeaf }
            if let start, selectedTile != nil, let next = layout.neighbor(of: start, direction, in: model) {
                onSelect?(next)
            } else if let start {
                onSelect?(start)
            }
            showKeyboardCard()
        } else if KeyCode.isReturn(event.keyCode), let selectedTile, model.tiles.indices.contains(selectedTile) {
            onActivate?(selectedTile)
        } else if event.keyCode == KeyCode.space {
            // Space: Quick Look for the selection, through the responder chain to the app delegate.
            NSApp.sendAction(#selector(AppDelegate.toggleQuickLook), to: nil, from: self)
        } else if event.keyCode == KeyCode.escape {
            cancelOperation(nil)  // Escape: a custom view receives the raw key
        } else {
            super.keyDown(with: event)
        }
    }

    /// The details the pointer card shows, for the tile chosen with the keyboard: anchored inside the tile's top left so
    /// it stays next to what it describes.
    private func showKeyboardCard() {
        cardTimer?.invalidate()
        pointerCard = nil
        keyboardCard = selectedTile != nil
        needsDisplay = true
    }

    private func hideKeyboardCard() {
        guard keyboardCard else { return }
        keyboardCard = false
        needsDisplay = true
    }

    private func cardAnchor(in frame: Frame, transform: CGAffineTransform) -> (tile: Int, point: CGPoint)? {
        if keyboardCard, let tile = selectedTile, frame.layout.rects.indices.contains(tile) {
            let rect = frame.layout.rects[tile].applying(transform)
            return (tile, CGPoint(x: min(rect.midX, rect.minX + 24), y: min(rect.midY, rect.minY + 12)))
        }
        if let pointerCard, let point = viewPoint(fromScreen: pointerCard),
            let hoverTile, tile(atPoint: point) == hoverTile
        {
            return (hoverTile, point)
        }
        return nil
    }

    override func cancelOperation(_ sender: Any?) {
        cardTimer?.invalidate()
        pointerCard = nil
        hideKeyboardCard()
        onCancel?()
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(copy(_:)) ? canCopy() : false
    }

    // MARK: Accessibility

    private func rebuildAccessibility(for frame: Frame) {
        let generation = frame.request.generation
        accessibilityTiles = TreemapAccessibility.elements(
            model: frame.model, view: self,
            screenFrame: { [weak self] in self?.accessibilityFrame(for: $0, generation: generation) },
            onSelect: { [weak self] in self?.select($0, activating: $1, generation: generation) ?? false })
        setAccessibilityValue(
            ProductCopy.MapAccess.value(
                summary: TreemapPresentation.summary(frame.model),
                exposed: accessibilityTiles.count { $0.accessibilityRole() != .staticText },
                total: frame.model.tiles.first?.childCount ?? 0))
        if window != nil { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }

    private func accessibilityFrame(for tile: Int, generation: Int) -> CGRect? {
        guard let current, current.request.generation == generation else { return nil }
        guard let window, !bounds.isEmpty else { return .zero }
        let rect = current.layout.rects[tile].applying(current.transform(to: bounds)).intersection(bounds)
        return rect.isEmpty ? .zero : window.convertToScreen(convert(rect, to: nil))
    }

    override func accessibilityChildren() -> [Any]? { accessibilityTiles }

    /// VoiceOver hears what was selected when the map has focus (the list announces its own rows).
    private func announceSelection() {
        guard current != nil, let selectedTile, window?.firstResponder === self,
            let content = cardProvider?(selectedTile)
        else {
            return
        }
        let text = ([content.title] + content.lines).joined(separator: ", ")
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
