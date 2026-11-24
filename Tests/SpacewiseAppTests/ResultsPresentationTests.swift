import AppKit
import SpacewiseAppModel
import SpacewiseCore
import Testing

@testable import SpacewiseApp

@MainActor struct ResultsPresentationTests {
    @Test func filterHandoffExpandsTheListAndKeepsOnlyListedSelections() throws {
        let result = Self.fixture(count: 8)
        let (app, toolbar) = makeApp(result: result)
        defer { app.window.close() }
        let list = app.controller.listTable
        app.controller.placeDefaultFocus(replacingCurrent: true)
        try #require(app.window.firstResponder === list)
        list.selectRowIndexes([2], byExtendingSelection: false)
        let selected = try #require(app.controller.selectedNodeID)

        app.controller.toggleList()
        let toggle = try #require(app.window.firstResponder as? NSButton)
        #expect(toggle.accessibilityLabel() == ProductCopy.Map.showList)
        #expect(list.acceptsFirstResponder == false && list.canBecomeKeyView == false)
        try send(#selector(NSResponder.moveDown(_:)), app: app, toolbar: toolbar)
        #expect(app.controller.listCollapsed == false)
        #expect(app.window.firstResponder === list)
        #expect(app.controller.selectedNodeID == selected && list.selectedRow == 2)

        app.controller.toggleList()
        let editor = try editFilter(app: app, toolbar: toolbar)
        try setFilter("no such entry", toolbar: toolbar)
        try send(#selector(NSResponder.insertNewline(_:)), app: app, toolbar: toolbar)
        #expect(app.window.firstResponder === editor)
        #expect(app.controller.listCollapsed)
        #expect(list.canBecomeKeyView == false)
        app.controller.toggleList()
        #expect(list.canBecomeKeyView == false)
        // Return can reach the delegate before the search action for the latest edit.
        editor.string = "photo"
        #expect(app.window.firstResponder === editor)
        try send(#selector(NSResponder.insertNewline(_:)), app: app, toolbar: toolbar)
        #expect(app.window.firstResponder === list && list.selectedRow == 0)

        _ = try editFilter(app: app, toolbar: toolbar)
        try setFilter("", toolbar: toolbar)
        let map = try #require(app.controller.treemapModel)
        let nested = try #require(map.tileIndex(forNode: 2))
        app.controller.treemapView.onSelect?(nested)
        try #require(app.controller.selectedNodeID == 2 && list.selectedRow == 0)
        try send(#selector(NSResponder.moveDown(_:)), app: app, toolbar: toolbar)
        #expect(app.controller.selectedNodeID == 1 && list.selectedRow == 0)
    }

    enum PendingChange: String, CaseIterable, Sendable {
        case none, noMatches, focus, query, sort, scope, result
    }

    @Test(arguments: PendingChange.allCases)
    func pendingHandoffIsScopedToTheOriginalEditingRequest(_ change: PendingChange) async throws {
        let result = Self.fixture(count: 400)
        let (app, toolbar) = makeApp(result: result)
        defer {
            app.session.treemapTask?.cancel()
            app.window.close()
        }
        let map = try #require(app.controller.treemapModel)
        let tile = try #require(map.tileIndex(forNode: 2))
        // This nested map selection is real but not itself a row in the current scope.
        app.controller.treemapView.onSelect?(tile)
        try #require(app.controller.selectedNodeID == 2)
        let list = app.controller.listTable
        app.controller.toggleList()
        let editor = try editFilter(app: app, toolbar: toolbar)
        try setFilter(change == .noMatches ? "no such entry" : "photo", toolbar: toolbar)
        try #require(app.controller.state.isPreparingRows)
        #expect(app.controller.selectedNodeID == 2 && list.selectedRow == -1)
        try send(#selector(NSResponder.insertNewline(_:)), app: app, toolbar: toolbar)
        #expect(app.window.firstResponder === editor)
        #expect(app.controller.listCollapsed)

        switch change {
        case .none, .noMatches: break
        case .focus:
            try #require(app.window.makeFirstResponder(app.controller.treemapView))
            // Reacquiring the same shared field editor must not revive the intent.
            try #require(editFilter(app: app, toolbar: toolbar) === editor)
        case .query:
            try setFilter("letter", toolbar: toolbar)
        case .sort:
            app.listSortDidChange(.init(key: .name, ascending: true))
        case .scope:
            app.session.navigate(to: 1)
        case .result:
            app.session.result = Self.fixture(count: 404)
            app.render()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while app.controller.state.isPreparingRows, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(app.controller.state.isPreparingRows == false)

        if change == .none {
            try #require(app.controller.state.source?.count == 200)
            #expect(app.window.firstResponder === list && list.selectedRow == 0)
            #expect(app.controller.selectedNodeID == app.controller.state.source?.node(at: 0)?.id)
            #expect(app.controller.listCollapsed == false)
            _ = try editFilter(app: app, toolbar: toolbar)
            app.render()
            #expect(app.window.firstResponder === editor)
        } else {
            #expect(app.window.firstResponder === editor)
            #expect(app.controller.listCollapsed)
            if change == .noMatches {
                #expect(app.controller.state.source?.count == 0)
                try setFilter("", toolbar: toolbar)
                #expect(app.window.firstResponder === editor)
            }
        }
    }

    @Test func readyDefaultAndPickerCancellationPreserveTheCurrentScreen() throws {
        var answer: Dialogs.FolderSelection?
        let (app, _) = makeApp(result: nil, chooseFolder: { _, completion in answer = completion })
        defer { app.window.close() }
        app.controller.placeDefaultFocus(replacingCurrent: true)
        #expect(app.window.firstResponder === app.window)
        #expect(app.window.defaultButtonCell === app.controller.scanButton.cell)
        let picker = try #require(
            views(in: app.controller.view, of: NSButton.self).first {
                $0.title == ProductCopy.Ready.folderButton
            })
        #expect(picker.action == #selector(AppDelegate.scanFolder))
        try #require(NSApp.sendAction(#selector(AppDelegate.scanFolder), to: picker.target, from: picker))
        let cancelReadyPicker = try #require(answer)
        cancelReadyPicker(nil)
        #expect(app.controller.state.phase == .ready && app.session.scanTask == nil)
        #expect(app.window.defaultButtonCell === app.controller.scanButton.cell)

        app.session.result = Self.fixture(count: 8)
        app.session.scopeRequest = ScopeRequest(parent: 0)
        app.render()
        let list = app.controller.listTable
        try #require(app.window.makeFirstResponder(list))
        app.controller.selectFirstListedRow()
        let selected = try #require(app.controller.selectedNodeID)
        #expect(app.window.defaultButtonCell == nil)
        answer = nil
        app.scanFolder()
        let cancelResultsPicker = try #require(answer)
        cancelResultsPicker(nil)
        #expect(app.controller.selectedNodeID == selected)
        #expect(app.window.firstResponder === list)
        #expect(app.controller.state.phase == .settled && app.session.scanTask == nil)
    }

    @Test(arguments: [840.0, 900.0, 1260.0])
    func bannerPreservesWarningsAndActionsAtSupportedWidths(width: Double) throws {
        let (app, _) = makeApp(result: nil)
        defer { app.window.close() }
        app.window.setContentSize(NSSize(width: width, height: WindowLayout.minimumContentSize.height))
        let banner = try #require(views(in: app.controller.view, of: BannerView.self).first)
        let name = String(repeating: "Very long scope name ", count: 30)
        var progress = ScanProgress()
        progress.entries = 12_345
        progress.issues[.denied] = 9_876
        var state = ScreenState()
        state.phase = .scanning
        state.status = StatusPresentation.outcome(phase: .scanning, progress: progress, scopeName: name)
        app.controller.render(state)
        app.controller.view.layoutSubtreeIfNeeded()
        let detail = try #require(
            views(in: banner, of: NSTextField.self).first {
                $0.stringValue.contains("couldn’t be read")
            })
        let scope = try #require(views(in: banner, of: NSTextField.self).first { $0.stringValue.contains(name) })
        #expect(detail.frame.width >= textWidth(detail))
        #expect(scope.frame.width < textWidth(scope))
        #expect(scope.frame.width > 80)

        progress.state = .limited
        progress.issues[.unresolvedVolume] = 1
        state.phase = .settled
        state.status = StatusPresentation.outcome(
            phase: .settled, progress: progress, scopeName: name, offersAccessSettings: true)
        app.controller.render(state)
        app.controller.view.layoutSubtreeIfNeeded()
        let title = try #require(
            views(in: banner, of: NSTextField.self).first {
                $0.stringValue.contains("isn’t in the totals")
            })
        let buttons = views(in: banner, of: NSButton.self)
        #expect(buttons.count == 3)
        #expect(title.frame.width >= textWidth(title))
        let titleRect = banner.convert(title.bounds, from: title)
        #expect(banner.bounds.contains(titleRect))
        for button in buttons {
            let rect = banner.convert(button.bounds, from: button)
            #expect(banner.bounds.contains(rect))
            #expect(button.frame.width >= button.intrinsicContentSize.width)
            #expect(titleRect.intersects(rect) == false)
        }
        let map = app.controller.treemapView
        #expect(map.bounds.height >= StorageMapPanel.minimumMapHeight)
        #expect(banner.frame.width <= CGFloat(width))
    }

    @Test func scopeCountsAndPageMatchesUseTheirOwnDenominators() throws {
        let result = Self.fixture(count: 300)
        let (app, _) = makeApp(result: result)
        defer { app.window.close() }
        let base = SettledRows(result: result, parent: 0)
        let page = SettledRows(result: result, ids: base.ids.sorted().dropFirst(256))
        let query = ListQuery(filter: "photo", sort: .init(key: .name, ascending: true))
        let filtered = QueriedRows(base: page, query: query)
        var state = app.controller.state
        state.isFiltering = true
        state.source = filtered
        state.phase = .scanning
        state.provisional = true
        state.livePage = LivePage(offset: 256, shown: page.count, discovered: base.count)
        app.controller.render(state)
        let header = try #require(views(in: app.controller.view, of: ScopeHeaderView.self).first)
        let metricLabels = views(in: header, of: MetricView.self).filter { !$0.isHidden }.map {
            $0.accessibilityLabel()
        }
        #expect(metricLabels.contains("Direct entries found: 301"))
        #expect(metricLabels.contains { $0?.hasPrefix("Matches") == true } == false)
        let footer = try #require(views(in: app.controller.view, of: FooterBar.self).first)
        let text = try #require(views(in: footer, of: NSTextField.self).first)
        #expect(text.stringValue == "Scan page 2 · 22 of 45 entries match")
        #expect(footer.previousButton.isEnabled && !footer.nextButton.isEnabled)

        state.phase = .settled
        state.provisional = false
        state.livePage = nil
        state.source = QueriedRows(base: base, query: query)
        app.controller.render(state)
        let settled = views(in: header, of: MetricView.self).filter { !$0.isHidden }.map { $0.accessibilityLabel() }
        #expect(settled.contains("Direct entries: 301") && settled.contains("Matches: 150"))
        #expect(footer.isHidden)
    }

    private func makeApp(
        result: ScanResult?,
        chooseFolder: @escaping Dialogs.FolderPicker = { _, _ in Issue.record("Unexpected picker") }
    ) -> (AppDelegate, MainToolbar) {
        _ = NSApplication.shared
        let app = AppDelegate(chooseFolder: chooseFolder)
        let window = ResultsTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        app.window = window
        app.controller.app = app
        window.contentViewController = app.controller
        app.controller.loadViewIfNeeded()
        app.controller.connectActions()
        app.session.delegate = app
        if let result {
            app.session.result = result
            app.session.topLevel = 0
            app.session.scopeRequest = ScopeRequest(parent: 0)
            app.session.treemapModel = result.treemap(parent: 0)
        }
        app.render()
        window.contentView?.layoutSubtreeIfNeeded()
        let toolbar = MainToolbar(target: app)
        let field = toolbar.filterItem.searchField
        field.frame = NSRect(x: 20, y: 20, width: 140, height: 25)
        // Exercise AppKit's shared field editor without opening a native toolbar or making the window key.
        app.controller.view.addSubview(field)
        return (app, toolbar)
    }

    private static func fixture(count: Int) -> ScanResult {
        var nodes = [
            ScanNode(
                id: 0, parent: nil, name: "Scope", kind: .directory, allocatedBytes: UInt64(10_000 + count),
                device: 1, inode: 1),
            ScanNode(id: 1, parent: 0, name: "Nested", kind: .directory, allocatedBytes: 10_000, device: 1, inode: 2),
            ScanNode(id: 2, parent: 1, name: "Nested.png", kind: .file, allocatedBytes: 10_000, device: 1, inode: 3),
        ]
        for offset in 0..<count {
            let name = offset.isMultiple(of: 2) ? "photo-\(offset).png" : "letter-\(offset).txt"
            nodes.append(
                ScanNode(
                    id: nodes.count, parent: 0, name: name, kind: .file, allocatedBytes: 1,
                    device: 1, inode: UInt64(nodes.count + 1)))
        }
        var progress = ScanProgress()
        progress.state = .completed
        return ScanResult(
            id: UUID(), started: Date(), ended: Date(), roots: [URL(fileURLWithPath: "/Scope")], nodes: nodes,
            progress: progress, coverage: LocationCoverage(wholeDrive: false), volumes: [])
    }

    private func editFilter(app: AppDelegate, toolbar: MainToolbar) throws -> NSTextView {
        let field = toolbar.filterItem.searchField
        try #require(app.window.makeFirstResponder(field))
        return try #require(field.currentEditor() as? NSTextView)
    }

    private func send(_ command: Selector, app: AppDelegate, toolbar: MainToolbar) throws {
        let field = toolbar.filterItem.searchField
        let editor = try (field.currentEditor() as? NSTextView) ?? editFilter(app: app, toolbar: toolbar)
        #expect(toolbar.control(field, textView: editor, doCommandBy: command))
    }

    private func setFilter(_ text: String, toolbar: MainToolbar) throws {
        let field = toolbar.filterItem.searchField
        field.stringValue = text
        (field.currentEditor() as? NSTextView)?.string = text
        let action = try #require(field.action)
        try #require(NSApp.sendAction(action, to: field.target, from: field))
    }

    private func views<T: NSView>(in view: NSView, of type: T.Type) -> [T] {
        let descendants = view.subviews.flatMap { views(in: $0, of: type) }
        return (view as? T).map { [$0] + descendants } ?? descendants
    }

    private func textWidth(_ label: NSTextField) -> CGFloat {
        ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width)
    }
}

// No native panel is ordered. The injected picker only needs the same visibility guard as an already open window.
@MainActor private final class ResultsTestWindow: NSWindow {
    override var isVisible: Bool { true }
}
