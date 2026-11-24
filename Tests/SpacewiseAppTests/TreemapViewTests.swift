import AppKit
import SpacewiseAppModel
import SpacewiseCore
import SpacewiseFixtures
import Testing

@testable import SpacewiseApp

@MainActor struct TreemapViewTests {
    private static let initialSize = CGSize(width: 674, height: 457)
    private static let largerSize = CGSize(width: 854, height: 577)
    private let result = PresentationFixtures.storageMap(tailFiles: 400)

    @Test func accessibilityCountsRealTilesAndExplainsWhereToBrowseOverflow() async throws {
        let (window, view) = makeWindow()
        defer { window.close() }
        let music = try #require(result.nodes.first { $0.name == "Music" })
        let flat = result.treemap(parent: music.id)
        view.setModel(flat)
        _ = try await waitForLayout(view, size: Self.initialSize)
        let top = try #require(view.accessibilityChildren() as? [TileAccessibilityElement])
        #expect(top.count == 61)
        #expect(top.filter { $0.accessibilityRole() == .button }.count == 60)
        let value = try #require(view.accessibilityValue() as? String)
        #expect(value.contains("60 of 80 map tiles available at this level"))
        let overflow = try #require(top.last)
        #expect(overflow.accessibilityRole() == .staticText)
        #expect(overflow.accessibilityPerformPress() == false)
        #expect(overflow.accessibilityLabel()?.contains("20 more map tiles at this level") == true)
        #expect(overflow.accessibilityLabel()?.contains("Show the Item List for this scope") == true)
        #expect(overflow.accessibilityLabel()?.contains("Clear any filter and check other pages") == true)

        let nested = result.treemap(parent: music.parent)
        view.setModel(nested)
        _ = try await waitForLayout(view, size: Self.initialSize)
        let folders = try #require(view.accessibilityChildren() as? [TileAccessibilityElement])
        let musicGroup = try #require(folders.first { $0.accessibilityLabel()?.hasPrefix("Music,") == true })
        #expect(musicGroup.accessibilityRole() == .group)
        let children = try #require(musicGroup.accessibilityChildren() as? [TileAccessibilityElement])
        let nestedOverflow = try #require(children.last)
        #expect(nestedOverflow.accessibilityRole() == .staticText)
        #expect(nestedOverflow.accessibilityLabel()?.contains("Zoom into this folder, then show the Item List") == true)

        let grouped = result.treemap(parent: music.id, limits: TreemapLimits(maxPerFolder: 68))
        let legend = FileTypeList.rows(for: grouped)
        let audioRow = try #require(legend.first { $0.category == .audio })
        let groupRow = try #require(legend.first { $0.category == .grouped })
        #expect(grouped.stats.itemsDrawn == audioRow.items)
        #expect(grouped.stats.itemsGrouped == groupRow.items && groupRow.items > 0)
        #expect(audioRow.items + groupRow.items == 80)
        #expect(audioRow.bytes + groupRow.bytes == grouped.rootWeight)
        #expect(abs(audioRow.share + groupRow.share - 1) < 1e-9)
        let summary = TreemapPresentation.summary(grouped)
        #expect(summary == "\(audioRow.items) individual tiles · \(groupRow.items) smaller entries grouped")
    }

    @Test func stretchedBitmapAndOverlaysStillTargetTheSameTiles() async throws {
        let (window, view) = makeWindow()
        defer { window.close() }
        let model = result.treemap(parent: 0)
        view.setModel(model)
        let layout = try await waitForLayout(view, size: Self.initialSize)
        let labels = TreemapLabelPlanner.plan(model: model, layout: layout, dark: false)
        let pill = try #require(labels.first { $0.pill && $0.tile != nil })
        let pillPoint = CGPoint(x: pill.rect.midX, y: pill.rect.midY)
        #expect(view.tile(atPoint: pillPoint) == pill.tile)

        let samples = stride(from: 21, to: Int(view.bounds.width), by: 31).flatMap { x in
            stride(from: 22, to: Int(view.bounds.height), by: 29).compactMap { y -> (CGPoint, Int)? in
                let point = CGPoint(x: x, y: y)
                return view.tile(atPoint: point).map { (point, $0) }
            }
        }
        #expect(Set(samples.map(\.1)).count > 8)
        let firstChild = try #require(model.tiles[0].children.first)
        let element = try #require(view.accessibilityChildren()?.first as? TileAccessibilityElement)
        let originalFrame = window.convertToScreen(view.convert(layout.rects[firstChild], to: nil))
        #expect(rectsMatch(element.accessibilityFrame(), originalFrame))

        window.setContentSize(Self.largerSize)
        #expect(view.bounds.size == Self.largerSize)
        #expect(view.mapLayout?.bounds.size == Self.initialSize)
        let sx = view.bounds.width / layout.bounds.width
        let sy = view.bounds.height / layout.bounds.height
        func stretch(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * sx, y: point.y * sy) }

        for (point, tile) in samples {
            #expect(view.tile(atPoint: stretch(point)) == tile)
        }
        let stretchedPill = stretch(pillPoint)
        #expect(view.tile(atPoint: stretchedPill) == pill.tile)

        let stretchedLayout = layout.scaled(x: sx, y: sy)
        let expectedFrame = window.convertToScreen(view.convert(stretchedLayout.rects[firstChild], to: nil))
        #expect(rectsMatch(element.accessibilityFrame(), expectedFrame))

        var selected: Int?
        var activated: Int?
        var menuTile: Int?
        view.onSelect = {
            selected = $0
            view.selectedTile = $0
        }
        view.onActivate = { activated = $0 }
        view.contextMenu = {
            menuTile = $0
            return nil
        }
        defer {
            view.onSelect = nil
            view.onActivate = nil
            view.contextMenu = nil
        }
        let inWindow = view.convert(stretchedPill, to: nil)
        view.mouseMoved(with: try mouse(.mouseMoved, at: inWindow, in: window))
        #expect(view.hoverTile == pill.tile)
        view.mouseDown(with: try mouse(.leftMouseDown, at: inWindow, in: window, clicks: 2))
        #expect(selected == pill.tile)
        #expect(activated == pill.tile)
        view.rightMouseDown(with: try mouse(.rightMouseDown, at: inWindow, in: window))
        #expect(menuTile == pill.tile)

        let keyStart = try #require(
            samples.lazy.map(\.1).first {
                stretchedLayout.neighbor(of: $0, .right, in: model) != nil
            })
        view.selectedTile = keyStart
        view.keyDown(with: try key(KeyCode.rightArrow, in: window))
        #expect(selected == stretchedLayout.neighbor(of: keyStart, .right, in: model))
        activated = nil
        view.keyDown(with: try key(KeyCode.returnKey, in: window))
        #expect(activated == selected)

        #expect(element.accessibilityPerformPress())
        #expect(selected == firstChild)
        let activate = try #require(element.accessibilityCustomActions()?.last?.handler)
        activated = nil
        #expect(activate())
        #expect(activated == firstChild)

        // Capture from AppKit at the retained render's scaled edge. Selecting the tile must paint there.
        let edge = stretchedLayout.rects[firstChild]
        let sample = CGPoint(x: edge.maxX - 1.5, y: edge.midY)
        view.mouseMoved(with: try mouse(.mouseMoved, at: CGPoint(x: -10, y: 0), in: window))
        #expect(view.hoverTile == nil)
        view.selectedTile = nil
        let before = try pixel(in: view, at: sample)
        view.selectedTile = firstChild
        let after = try pixel(in: view, at: sample)
        #expect(after.redComponent > before.redComponent + 0.15)
        #expect(after.greenComponent > before.greenComponent + 0.15)
        #expect(after.blueComponent > before.blueComponent + 0.15)

        let settled = try await waitForLayout(view, size: Self.largerSize)
        #expect(view.accessibilityChildren()?.first as? TileAccessibilityElement === element)
        let settledFrame = window.convertToScreen(view.convert(settled.rects[firstChild], to: nil))
        #expect(rectsMatch(element.accessibilityFrame(), settledFrame))
        #expect(view.selectedTile == firstChild)
    }

    @Test func returningToRenderedSizeCancelsResizeAndRefreshRejectsRetainedElements() async throws {
        let (window, view) = makeWindow()
        defer { window.close() }
        let top = result.treemap(parent: 0)
        view.setModel(top)
        let original = try await waitForLayout(view, size: Self.initialSize)
        let folder = try #require(view.accessibilityChildren()?.first as? TileAccessibilityElement)
        let child = try #require(folder.accessibilityChildren()?.first as? TileAccessibilityElement)
        let folderActions = try #require(folder.accessibilityCustomActions())
        let childAction = try #require(child.accessibilityCustomActions()?.last?.handler)

        window.setContentSize(Self.largerSize)
        window.setContentSize(Self.initialSize)
        let deadline = ContinuousClock.now + .milliseconds(350)
        repeat {
            #expect(view.mapLayout?.rects == original.rects)
            try await Task.sleep(for: .milliseconds(15))
        } while ContinuousClock.now < deadline

        var selections: [Int] = []
        var activations: [Int] = []
        view.onSelect = { if let tile = $0 { selections.append(tile) } }
        view.onActivate = { activations.append($0) }
        #expect(childAction())
        #expect(selections.count == 1)
        #expect(activations == selections)
        let oldNode = top.tiles[try #require(selections.first)].nodeID
        selections.removeAll()
        activations.removeAll()

        let folderIndex = try #require(top.tiles[0].children.first)
        let inside = result.treemap(parent: top.tiles[folderIndex].nodeID)
        #expect(inside.tiles[folderIndex].nodeID != top.tiles[folderIndex].nodeID)
        #expect(inside.tiles.dropFirst().contains { $0.nodeID == oldNode })
        view.setModel(inside)
        #expect(view.accessibilityChildren()?.isEmpty == true)
        #expect(folder.accessibilityPerformPress() == false)
        #expect(childAction() == false)
        #expect(view.tile(atPoint: CGPoint(x: 30, y: 30)) == nil)

        _ = try await waitForLayout(view, size: Self.initialSize)
        #expect(folder.accessibilityFrame() == .zero)
        #expect(folder.accessibilityChildren() == nil)
        #expect(child.accessibilityPerformPress() == false)
        #expect(childAction() == false)
        for action in folderActions {
            let invoke = try #require(action.handler)
            #expect(invoke() == false)
        }
        #expect(selections.isEmpty)
        #expect(activations.isEmpty)
        let fresh = try #require(view.accessibilityChildren()?.first as? TileAccessibilityElement)
        #expect(fresh.accessibilityPerformPress())
        #expect(selections == [inside.tiles[0].firstChild])

        // A Select callback can replace the model before the second half of a custom action runs.
        let freshAction = try #require(fresh.accessibilityCustomActions()?.last?.handler)
        view.onSelect = { [weak view] _ in view?.setModel(top) }
        #expect(freshAction() == false)
        #expect(activations.isEmpty)
    }

    @Test func resizeSettlesWithTheLatestAppearance() async throws {
        let (window, view) = makeWindow()
        defer { window.close() }
        // With no tiles, the opaque bitmap's backdrop color identifies the appearance of the rendered frame.
        view.setModel(PresentationFixtures.scenario(.empty).result.treemap(parent: 0))
        _ = try await waitForLayout(view, size: Self.initialSize)
        window.setContentSize(Self.largerSize)
        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let light = try pixel(in: view, at: centre)
        #expect(light.redComponent > 0.7)

        view.appearance = NSAppearance(named: .darkAqua)
        _ = try await waitForLayout(view, size: Self.largerSize)
        let dark = try pixel(in: view, at: centre)
        #expect(dark.redComponent < 0.3)

        view.appearance = NSAppearance(named: .aqua)
        let deadline = ContinuousClock.now + .seconds(5)
        var restored = try pixel(in: view, at: centre)
        while restored.redComponent <= 0.7, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
            restored = try pixel(in: view, at: centre)
        }
        #expect(restored.redComponent > 0.7)
        #expect(view.mapLayout?.bounds.size == Self.largerSize)
    }

    private func makeWindow() -> (NSWindow, TreemapView) {
        _ = NSApplication.shared
        let rect = CGRect(origin: .zero, size: Self.initialSize)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TreemapView(frame: rect)
        view.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        return (window, view)
    }

    private func waitForLayout(_ view: TreemapView, size: CGSize) async throws -> TreemapLayout {
        let deadline = ContinuousClock.now + .seconds(5)
        while view.mapLayout?.bounds.size != size, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let layout = try #require(view.mapLayout)
        try #require(layout.bounds.size == size)
        return layout
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow, clicks: Int = 0) throws
        -> NSEvent
    {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: clicks, pressure: 0))
    }

    private func key(_ code: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    private func pixel(in view: TreemapView, at point: CGPoint) throws -> NSColor {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let x = Int(point.x / view.bounds.width * CGFloat(bitmap.pixelsWide))
        let y = Int(point.y / view.bounds.height * CGFloat(bitmap.pixelsHigh))
        return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func rectsMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }
}
