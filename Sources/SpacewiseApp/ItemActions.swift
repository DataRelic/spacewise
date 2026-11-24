import AppKit
import Quartz
import SpacewiseAppModel
import SpacewiseCore

/// Location actions and the context menu shared by the item list and map.
@MainActor enum ItemActions {
    typealias TrashMover = @Sendable (URL) throws -> Void

    static nonisolated func moveToTrash(_ target: TrashTarget, using mover: @escaping TrashMover) async throws {
        // FileManager's synchronous Trash operation and its filesystem checks can both block.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try target.move(using: mover) })
            }
        }
    }

    static func copy(path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// True when something is still at the path. lstat-based: a symbolic link or a vanished item must not be resolved.
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Shows the item in Finder. Returns false, revealing nothing, when nothing is at that path any more.
    static func reveal(_ url: URL) -> Bool {
        guard exists(url) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    static func open(
        _ target: ItemHandoffTarget, using handoff: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Result<Void, ItemHandoffTarget.Failure> {
        target.currentFacts().flatMap { facts in
            guard ItemOpenRule.open(facts) == .open else { return .failure(.restricted) }
            return handoff(target.url) ? .success(()) : .failure(.refused)
        }
    }

    static func preview(_ target: ItemHandoffTarget) -> Result<URL, ItemHandoffTarget.Failure> {
        target.currentFacts().flatMap { facts in
            ItemOpenRule.canQuickLook(facts) ? .success(target.url) : .failure(.restricted)
        }
    }

    /// The item menu for a list row or map tile. The app delegate validates each action. Open is left out for
    /// items the Open rule holds back, since Show in Finder, which follows it, is what they offer. The map names opening
    /// a folder "Zoom Into Folder", as it zooms; the list names it "Open Folder", as the Go menu does.
    static func rowMenu(
        target: AppDelegate, node: Int, canOpenFolder: Bool, open: OpenBehavior,
        openFolderTitle: String = ProductCopy.Menu.openFolder
    ) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        if canOpenFolder { add(openFolderTitle, #selector(AppDelegate.drill)) }
        if open != .showInFinderOnly { add(ProductCopy.Commands.open, #selector(AppDelegate.openItem)) }
        add(ProductCopy.Commands.quickLook, #selector(AppDelegate.toggleQuickLook))
        menu.addItem(.separator())
        add(ProductCopy.Inspector.showInFinder, #selector(AppDelegate.showInFinder))
        add(ProductCopy.Inspector.copyPath, #selector(AppDelegate.copyPath))
        if let trashTarget = target.availableTrashTarget(for: node) {
            menu.addItem(.separator())
            add("Move to Trash…", #selector(AppDelegate.moveToTrash(_:)))
            menu.items.last?.representedObject = trashTarget
        }
        return menu
    }
}

/// Feeds the shared Quick Look panel the selected item. The app delegate takes control of the panel when it opens
/// (it is the last responder, so the list and the map both reach it) and hands it to this object.
@MainActor final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var target: ItemHandoffTarget?
    private weak var panel: QLPreviewPanel?
    var onFailure: ((ItemHandoffTarget, ItemHandoffTarget.Failure) -> Void)?

    var isShowing: Bool { target != nil }

    func show(_ target: ItemHandoffTarget) {
        self.target = target
        guard validatedURL() != nil else { return }
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    func close() {
        guard isShowing else { return }
        target = nil
        if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().orderOut(nil) }
    }

    /// The panel follows the selection while it is open.
    func selectionDidChange(to target: ItemHandoffTarget?) {
        guard isShowing else { return }
        guard let target else {
            close()
            return
        }
        self.target = target
        if validatedURL() != nil { panel?.reloadData() }
    }

    func begin(_ panel: QLPreviewPanel) {
        self.panel = panel
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func end(_ panel: QLPreviewPanel) {
        target = nil
        panel.dataSource = nil
        panel.delegate = nil
        self.panel = nil
    }

    private func validatedURL(fromDataSource: Bool = false) -> URL? {
        guard let target else { return nil }
        switch ItemActions.preview(target) {
        case .success(let url):
            return url
        case .failure(let failure):
            if fromDataSource {
                // Ordering out the panel from its data source would reenter AppKit during reload.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.target == target else { return }
                    self.fail(target, failure)
                }
            } else {
                fail(target, failure)
            }
            return nil
        }
    }

    private func fail(_ target: ItemHandoffTarget, _ failure: ItemHandoffTarget.Failure) {
        close()
        onFailure?(target, failure)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { validatedURL(fromDataSource: true) == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url = MainActor.assumeIsolated { validatedURL(fromDataSource: true) }
        return url.map { $0 as NSURL }
    }

    /// Space in the panel closes it, as in Finder.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, event.keyCode == KeyCode.space else { return false }
        MainActor.assumeIsolated { close() }
        return true
    }
}
