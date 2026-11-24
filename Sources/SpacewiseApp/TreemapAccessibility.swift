import AppKit
import SpacewiseCore

/// One map tile as VoiceOver sees it. A folder whose contents are drawn is a group: open it to reach its contents
/// (built when first asked for). Anything else is a button that selects the tile. Folders and packages offer Zoom In,
/// files Show in Finder, as custom actions. The frame is computed from the view when asked, so it follows the window.
final class TileAccessibilityElement: NSAccessibilityElement {
    private let screenFrame: @MainActor () -> CGRect?
    private let onPress: @MainActor () -> Bool
    /// Builds the contents of a drawn folder, the first time VoiceOver opens it. Nil for anything else.
    var makeChildren: ((TileAccessibilityElement) -> [TileAccessibilityElement])?
    private var builtChildren: [TileAccessibilityElement]?

    init(screenFrame: @escaping @MainActor () -> CGRect?, onPress: @escaping @MainActor () -> Bool) {
        self.screenFrame = screenFrame
        self.onPress = onPress
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated { [onPress] in onPress() }
    }

    override func accessibilityFrame() -> NSRect {
        MainActor.assumeIsolated { [screenFrame] in screenFrame() ?? .zero }
    }

    override func accessibilityChildren() -> [Any]? {
        guard let makeChildren, MainActor.assumeIsolated({ [screenFrame] in screenFrame() != nil }) else { return nil }
        if builtChildren == nil { builtChildren = makeChildren(self) }
        return builtChildren
    }
}

/// The map's accessibility structure, mirroring the map itself: the tiles directly under the scope in size order, each
/// numbered among its siblings ("2 of 6"), with drawn folders openable down to their own contents. An overflow note
/// counts additional map tiles at that level and explains how to browse the corresponding scope.
/// Not main-actor bound: it only reads the immutable model and configures elements, and VoiceOver opens folders on
/// the main thread.
enum TreemapAccessibility {
    /// The most children exposed per folder (largest first).
    private static let maximumChildren = 60
    /// Folders deeper than this are buttons, not groups: zoom in to explore further.
    private static let maximumDepth = 4

    static func elements(
        model: TreemapModel, view: NSView,
        screenFrame: @escaping @MainActor (Int) -> CGRect?,
        onSelect: @escaping @MainActor (Int, Bool) -> Bool
    ) -> [TileAccessibilityElement] {
        guard !model.isEmpty else { return [] }
        return children(
            of: 0, container: view, model: model, screenFrame: screenFrame, onSelect: onSelect)
    }

    /// `container` is the accessibility parent: the map view at the top, the folder's own element below it.
    private static func children(
        of parent: Int, container: Any, model: TreemapModel,
        screenFrame: @escaping @MainActor (Int) -> CGRect?,
        onSelect: @escaping @MainActor (Int, Bool) -> Bool
    ) -> [TileAccessibilityElement] {
        let siblings = model.tiles[parent].children
        var elements: [TileAccessibilityElement] = []
        for (offset, index) in siblings.prefix(maximumChildren).enumerated() {
            guard let detail = TreemapPresentation.detail(tile: index, in: model) else { continue }
            let tile = model.tiles[index]
            let label = ProductCopy.MapAccess.tile(detail.accessibility, position: offset + 1, of: siblings.count)
            let opens = tile.kind == .folder && !tile.isLeaf && tile.depth < maximumDepth
            let element = TileAccessibilityElement(
                screenFrame: { screenFrame(index) }, onPress: { onSelect(index, false) })
            if opens {
                element.makeChildren = { folder in
                    children(of: index, container: folder, model: model, screenFrame: screenFrame, onSelect: onSelect)
                }
            }
            element.setAccessibilityRole(opens ? .group : .button)
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(container)
            var actions: [NSAccessibilityCustomAction] = []
            if opens {
                actions.append(
                    NSAccessibilityCustomAction(name: ProductCopy.MapAccess.select) {
                        MainActor.assumeIsolated { onSelect(index, false) }
                    })
            }
            if tile.nodeID >= 0 {
                let name = tile.kind == .file ? ProductCopy.MapAccess.showInFinder : ProductCopy.MapAccess.zoomIn
                actions.append(
                    NSAccessibilityCustomAction(name: name) {
                        MainActor.assumeIsolated { onSelect(index, true) }
                    })
            }
            element.setAccessibilityCustomActions(actions)
            elements.append(element)
        }
        if siblings.count > maximumChildren {
            let more = TileAccessibilityElement(screenFrame: { screenFrame(parent) }, onPress: { false })
            more.setAccessibilityRole(.staticText)
            more.setAccessibilityLabel(
                ProductCopy.MapAccess.overflow(siblings.count - maximumChildren, nested: parent != 0))
            more.setAccessibilityParent(container)
            elements.append(more)
        }
        return elements
    }
}
