import AppKit
import SpacewiseAppModel
import SpacewiseCore

/// How the map and the list share the results height. The divider is placed from the row count when a scope first
/// shows rows and once more when a scan settles; it never moves with row growth during a scan, and never after the
/// person drags it (until they reset it). The list can also collapse to its header.
@MainActor final class ResultsSplitController: NSObject, NSSplitViewDelegate {
    let split = NSSplitView()
    private let map: NSView
    private let list: NSView
    private(set) var userSplit = false
    private(set) var listCollapsed = false
    private var programmaticSplit = false
    private var placedKey = ""
    private var lastPlacedHeight: CGFloat = 0
    private var mapHeightBeforeCollapse: CGFloat?
    /// Called whenever the list collapses or expands.
    var onListCollapsedChange: ((Bool) -> Void)?

    init(map: NSView, list: NSView) {
        self.map = map
        self.list = list
        super.init()
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(map)
        split.addArrangedSubview(list)
        split.setHoldingPriority(NSLayoutConstraint.Priority(251), forSubviewAt: 1)
        split.setHoldingPriority(NSLayoutConstraint.Priority(249), forSubviewAt: 0)
        split.translatesAutoresizingMaskIntoConstraints = false
        split.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    var listHeight: CGFloat { list.frame.height }

    // MARK: Placement

    private func place(divider position: CGFloat) {
        programmaticSplit = true
        defer { programmaticSplit = false }
        split.setPosition(position.rounded(), ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
    }

    /// 75–85 percent map when only a few rows exist, a useful list otherwise, more room in a large window.
    /// `showing` is false while the results are hidden (the Ready screen).
    func applyAdaptive(_ state: ScreenState, showing: Bool, force: Bool = false) {
        guard showing, state.phase != .ready else { return }
        let available = split.bounds.height
        guard available > 260, !listCollapsed else { return }
        if userSplit && !force { return }
        let live = state.phase == .scanning || state.phase == .stopping
        let rows = state.total
        if live && rows == 0 && !force { return }  // wait for the first rows so the divider is placed once, not twice
        let scope = state.summary?.parent.map(String.init) ?? "top"
        let key = "\(scope)|\(live ? "live" : "settled")|\(state.isFolderScope)"
        guard force || key != placedKey || abs(available - lastPlacedHeight) > 140 else { return }
        placedKey = key
        lastPlacedHeight = available
        let target = SplitPolicy.dividerPosition(rowCount: rows, available: available)
        if abs(target - map.frame.height) >= 6 || force { place(divider: target) }
    }

    /// Forget the person's divider and any collapse, and place the divider adaptively again.
    func reset(_ state: ScreenState, showing: Bool) {
        userSplit = false
        listCollapsed = false
        onListCollapsedChange?(listCollapsed)
        placedKey = ""
        applyAdaptive(state, showing: showing, force: true)
    }

    func toggleList(rowCount: Int) {
        listCollapsed.toggle()
        onListCollapsedChange?(listCollapsed)
        if listCollapsed {
            mapHeightBeforeCollapse = map.frame.height
            place(divider: split.bounds.height - SplitPolicy.collapsedList)
        } else {
            // Return to where the list was, which is the adaptive placement unless the person had moved the divider.
            let available = split.bounds.height
            place(
                divider: mapHeightBeforeCollapse
                    ?? SplitPolicy.dividerPosition(rowCount: rowCount, available: available))
        }
    }

    // MARK: NSSplitViewDelegate

    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        proposedMinimumPosition + SplitPolicy.minimumMap
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        proposedMaximumPosition - SplitPolicy.collapsedList
    }

    /// Only a drag of the divider carries NSSplitViewDividerIndex; window resizes and our own placement do not.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        // AppKit applies our own placement on a later layout pass, so the flag alone is not enough: a person's drag happens
        // while a mouse event is in flight.
        guard !programmaticSplit, notification.userInfo?["NSSplitViewDividerIndex"] != nil,
            let type = NSApp.currentEvent?.type,
            type == .leftMouseDragged || type == .leftMouseDown || type == .leftMouseUp
        else { return }
        userSplit = true
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}
