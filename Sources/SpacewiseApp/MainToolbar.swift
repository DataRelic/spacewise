import AppKit
import SpacewiseCore

/// The window toolbar. Its items act on the app delegate, which also validates them, so the toolbar and the menu bar
/// agree on what is available.
@MainActor final class MainToolbar: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    static let filterID = NSToolbarItem.Identifier("filter")

    private struct Item {
        let id: String
        let label: String
        let tip: String
        let symbol: String
        let action: Selector
    }

    private static let items: [Item] = {
        let copy = ProductCopy.Toolbar.self
        return [
            Item(
                id: "trash", label: "Move to Trash…", tip: "Move the selected personal file to the Trash",
                symbol: "trash", action: #selector(AppDelegate.moveToTrash(_:))),
            Item(id: "up", label: copy.up, tip: copy.upTip, symbol: "chevron.up", action: #selector(AppDelegate.up)),
            Item(
                id: "scan", label: copy.scan, tip: copy.scanTip, symbol: "internaldrive",
                action: #selector(AppDelegate.scanInternal)),
            Item(
                id: "folder", label: copy.folder, tip: copy.folderTip, symbol: "folder.badge.plus",
                action: #selector(AppDelegate.scanFolder)),
            Item(
                id: "stop", label: copy.stop, tip: copy.stopTip, symbol: "stop.circle",
                action: #selector(AppDelegate.cancel)),
            Item(
                id: "coverage", label: copy.scanDetails, tip: copy.scanDetailsTip, symbol: "list.bullet.rectangle",
                action: #selector(AppDelegate.showCoverage)),
            Item(
                id: "inspector", label: copy.inspector, tip: copy.inspectorTip, symbol: "sidebar.right",
                action: #selector(AppDelegate.toggleInspector)),
        ]
    }()

    private weak var target: AppDelegate?
    /// The list's name filter. Built once, so its text survives the toolbar re-creating its item.
    private(set) lazy var filterItem: NSSearchToolbarItem = {
        let item = NSSearchToolbarItem(itemIdentifier: Self.filterID)
        let copy = ProductCopy.Filter.self
        item.label = copy.label
        item.paletteLabel = copy.label
        item.toolTip = copy.tip
        item.preferredWidthForSearchField = 140
        item.resignsFirstResponderWithCancel = true
        let field = item.searchField
        field.placeholderString = copy.placeholder
        field.setAccessibilityLabel(copy.placeholder)
        field.font = Typography.body
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = self
        field.target = self
        field.action = #selector(filterEdited(_:))
        return item
    }()

    init(target: AppDelegate) {
        self.target = target
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .init("up"), .flexibleSpace, .init("scan"), .init("folder"), .init("stop"), .space, .init("coverage"),
            .init("trash"), .init("inspector"), Self.filterID,
        ]
    }

    // MARK: Filter

    func focusFilter(in window: NSWindow) {
        guard window.toolbar?.isVisible == true, window.toolbar?.items.contains(filterItem) == true else { return }
        filterItem.beginSearchInteraction()
    }

    /// Empties the field without reporting a change (the list has already dropped the filter).
    func clearFilter() {
        filterItem.searchField.stringValue = ""
    }

    /// Sent on every keystroke, and when the field is cleared with its button or Escape.
    @objc private func filterEdited(_ sender: NSSearchField) {
        target?.filterDidChange(sender.stringValue)
    }

    /// Return and the down arrow move from the field to the list, so the keyboard can carry on from a filter.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === filterItem.searchField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)):
            target?.filterDidFinish(from: control, editor: textView)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        target?.cancelFilterHandoff()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == Self.filterID { return filterItem }
        guard let spec = Self.items.first(where: { $0.id == itemIdentifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = spec.label
        item.paletteLabel = spec.label
        item.toolTip = spec.tip
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        item.target = target
        item.action = spec.action
        item.isBordered = true
        return item
    }
}
