import AppKit
import Darwin
import Quartz
import SpacewiseAppModel
import SpacewiseCore
import os

/// The app's lifecycle and its command target. Menus, the toolbar and the window's buttons send their actions here;
/// each one is a short hand-off to the scan session, the main view controller, the dialogs or the item actions.
/// Presentation rules live in SpacewiseCore and SpacewiseAppModel, layout in the views.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation,
    NSToolbarItemValidation, NSDraggingDestination, ScanSessionDelegate
{
    var window: NSWindow!
    let controller = MainViewController()
    let session = ScanSession()
    private lazy var toolbar = MainToolbar(target: self)
    private var closing = false
    /// A quit during a scan is being asked about or carried out.
    private var quitting = false
    /// Set once the person agreed to stop the scan and quit: AppKit is answered when the scan settles or the deadline
    /// passes, whichever comes first.
    private var quitWait: QuitWait?
    private var quitDeadline: Timer?
    private static let log = Logger(subsystem: SpacewiseLog.subsystem, category: "app")
    private var closeQuestionPending = false
    private enum TrashAction { case confirming, moving, reporting }
    private var trashAction: TrashAction?
    /// A successful move or a stale check can leave an obsolete row visible until a refresh is admitted.
    private var unavailableTrashTargets: [URL: UUID] = [:]
    /// The person's filter and sort for the list, and the queried rows built from them.
    var listQuery = ListQuery()
    private let listQueryCache = ListQueryCache()
    /// The folder the filter was typed in; moving to another folder clears it.
    private var filterScope: Int??
    private struct FilterHandoff {
        let scope: ScopeRequest
        let scanID: UUID?
        let query: ListQuery
        weak var field: NSControl?
        weak var editor: NSTextView?

        @MainActor func hasFocus(in window: NSWindow) -> Bool {
            guard let field, let editor else { return false }
            return field.window === window && field.currentEditor() === editor && window.firstResponder === editor
        }
    }
    private var filterHandoff: FilterHandoff?
    private lazy var quickLook: QuickLookCoordinator = {
        let coordinator = QuickLookCoordinator()
        coordinator.onFailure = { [weak self] target, failure in self?.showHandoffFailure(failure, target: target) }
        return coordinator
    }()
    private var signalSource: DispatchSourceSignal?
    private var volumeContext: VolumeContext?
    private var clockTimer: Timer?
    let identity = BuildInfo.identity
    var inspectorShown: Bool { controller.inspectorVisible }
    static weak var shared: AppDelegate?
    /// A folder the app was launched with, which arrives before the window exists.
    private var launchFolder = LaunchFolder()
    private var pendingScanAction: UUID?
    private let chooseFolder: Dialogs.FolderPicker
    private let presentAlert: Dialogs.AlertPresenter
    private let trashMover: ItemActions.TrashMover
    private let replyToQuit: @MainActor (Bool) -> Void

    convenience init(chooseFolder: @escaping Dialogs.FolderPicker = Dialogs.chooseFolder) {
        self.init(presentAlert: Dialogs.presentAlert, chooseFolder: chooseFolder)
    }

    init(
        presentAlert: @escaping Dialogs.AlertPresenter,
        trashMover: @escaping ItemActions.TrashMover = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        },
        replyToQuit: @escaping @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) },
        chooseFolder: @escaping Dialogs.FolderPicker = Dialogs.chooseFolder
    ) {
        self.trashMover = trashMover
        self.presentAlert = presentAlert
        self.replyToQuit = replyToQuit
        self.chooseFolder = chooseFolder
        super.init()
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install(target: self)
        session.delegate = self
        controller.app = self
        window = MainWindow.make(controller: controller, delegate: self, toolbarDelegate: toolbar)
        window.registerForDraggedTypes([.fileURL])
        listQuery.sort = controller.listSort ?? .standard
        refreshVolume()
        render()
        showWindow()
        controller.placeDefaultFocus(replacingCurrent: true)
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { AppDelegate.shared?.render() }
        }
        signal(SIGTERM, SIG_IGN)
        signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signalSource?.setEventHandler {
            // terminateLater runs a nested application loop. Return from the dispatch
            // source before entering it so the owned MainActor scan task can settle.
            RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        }
        signalSource?.resume()
        AppDelegate.shared = self
        if let folder = launchFolder.windowBecameReady() { startFolderScan(folder) }
    }

    @objc func about() { Dialogs.showAbout(identity: identity) }

    /// Reopens the main window (Dock icon, a scan started while hidden, or a question that needs it).
    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    /// A folder dropped on the Dock icon, or opened with Spacewise from Finder, is scanned like a chosen folder.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let chosen = urls.first(where: Self.isFolder), let folder = launchFolder.received(chosen) else { return }
        showWindow()
        startFolderScan(folder)
    }

    nonisolated static func isFolder(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    // MARK: Dropping a folder on the window

    private func droppedFolder(_ info: any NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        // One folder at a time: a scan has one root.
        guard urls.count == 1, let url = urls.first, Self.isFolder(url) else { return nil }
        return url
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard canStartScan, droppedFolder(sender) != nil else { return [] }
        return .generic
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard canStartScan, let url = droppedFolder(sender) else { return false }
        // Ask after the drop has finished, so the sheet does not appear inside the drag session.
        afterScanSheet { $0.startFolderScan(url) }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshVolume()
        render()
    }

    func refreshVolume() {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        volumeContext = VolumeContext(root: root, scope: ProductCopy.Scope.startupDisk)
    }

    // MARK: Confirmations

    /// Asks the person in a sheet on the main window; `answer` receives true to go ahead. The window is shown first, so a question is never asked on a hidden window.
    private func confirm(_ question: Confirmation, answer: @escaping (Bool) -> Void) {
        if !window.isVisible || window.isMiniaturized { showWindow() }
        presentAlert(Dialogs.confirmationAlert(question), window) { response in
            answer(response == .alertSecondButtonReturn)
        }
    }

    /// Runs `start` once the person agrees to replace the results on screen (at once when there are none).
    private func replacingResults(_ start: @escaping () -> Void) {
        guard let resultID = session.result?.id else {
            start()
            return
        }
        confirm(.replaceResults) { [weak self] agreed in
            guard agreed, let self else { return }
            self.afterScanSheet { app in
                guard app.session.result?.id == resultID else { return }
                start()
            }
        }
    }

    /// Keeps another scan request from overtaking a deferred sheet answer or drop.
    private func afterScanSheet(_ action: @escaping (AppDelegate) -> Void) {
        let id = UUID()
        pendingScanAction = id
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingScanAction == id else { return }
            self.pendingScanAction = nil
            guard self.canStartScan, self.window.isVisible else { return }
            action(self)
        }
    }

    private var isAsking: Bool { pendingScanAction != nil || window?.attachedSheet != nil }
    private var canStartScan: Bool {
        !session.isLive && !isAsking && trashAction == nil && !closeQuestionPending && !closing && !quitting
    }

    // MARK: Starting scans (explicit user actions only)

    @objc func scanInternal() {
        guard canStartScan else { return }
        replacingResults { [weak self] in self?.session.start(.internalDisk) }
    }

    @objc func scanFolder() {
        guard canStartScan else { return }
        cancelFilterHandoff()
        if !window.isVisible || window.isMiniaturized { showWindow() }
        let id = UUID()
        pendingScanAction = id
        chooseFolder(window) { [weak self] url in
            guard let self, self.pendingScanAction == id else { return }
            self.pendingScanAction = nil
            guard let url else { return }
            // The panel's sheet is still closing when this runs; ask the next question once it has gone.
            self.afterScanSheet { $0.startFolderScan(url) }
        }
    }

    /// Scans a folder the person chose or dropped, through the same confirmation as Choose Folder.
    func startFolderScan(_ url: URL) {
        guard canStartScan else { return }
        replacingResults { [weak self] in self?.session.start(ScanPlan(folder: url)) }
    }

    @objc func rescan() {
        guard canStartScan, let plan = session.lastPlan else { return }
        replacingResults { [weak self] in self?.session.start(plan) }
    }

    // MARK: Stop, close, quit

    /// Stop was pressed: the person asked for exactly this, so it happens without a question. Closing the window and
    /// quitting, which end the scan as a side effect, still ask.
    @objc func cancel() {
        guard session.scanTask != nil, !session.stopping else { return }
        session.stop()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard trashAction != .moving, !quitting, !closing, !closeQuestionPending else { return false }
        guard session.scanTask != nil else { return true }
        endOpenQuestion()
        closeQuestionPending = true
        confirm(.closeDuringScan) { [weak self] agreed in
            guard let self else { return }
            self.closeQuestionPending = false
            guard agreed else { return }
            guard self.session.scanTask != nil else {
                self.window.close()
                return
            }
            self.closing = true
            self.session.stop()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        listQueryCache.cancel()
        session.rowRankingTask?.cancel()
    }

    /// While a scan runs, quitting asks in a sheet and returns `.terminateLater`. AppKit then waits (in a modal run
    /// loop mode, where the sheet and the scan task both keep running) for `reply(toApplicationShouldTerminate:)`:
    /// false when the person keeps scanning; true once the stopped scan has settled, or after `QuitWait.limitSeconds`
    /// if it has not, so a scanner stuck in a slow system call cannot keep the app from quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        guard trashAction != .moving, !closeQuestionPending, !closing else { return .terminateCancel }
        guard session.scanTask != nil else { return .terminateNow }
        endOpenQuestion()
        quitting = true
        confirm(.quitDuringScan) { [weak self] agreed in
            guard let self else { return }
            guard agreed else {
                self.quitting = false
                self.replyToQuit(false)
                return
            }
            self.quitWait = QuitWait()
            // The scan may have finished while the question was open; then there is nothing left to stop.
            guard self.session.scanTask != nil else {
                self.finishQuit(self.quitWait?.scanSettled())
                return
            }
            self.session.stop()
            self.startQuitDeadline()
        }
        return .terminateLater
    }

    /// Quits after `QuitWait.limitSeconds` if the stopped scan has not settled by then. The timer runs in the common
    /// modes, which include the modal mode AppKit waits in after `.terminateLater`.
    private func startQuitDeadline() {
        let deadline = Timer(timeInterval: QuitWait.limitSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitDeadlinePassed() }
        }
        RunLoop.main.add(deadline, forMode: .common)
        quitDeadline = deadline
    }

    private func quitDeadlinePassed() {
        guard let reply = quitWait?.deadlinePassed() else { return }
        Self.log.error(
            "quit stopped waiting for the scan to settle reason=timeout waitedSeconds=\(QuitWait.limitSeconds, privacy: .public)"
        )
        finishQuit(reply)
    }

    /// Answers AppKit's pending terminate request; nil means it was already answered.
    private func finishQuit(_ reply: QuitWait.Reply?) {
        guard reply != nil else { return }
        quitDeadline?.invalidate()
        quitDeadline = nil
        replyToQuit(true)
    }

    /// Dismisses an open question (a replace confirmation or the folder panel) as cancelled, so a close or quit
    /// question can take its place.
    private func endOpenQuestion() {
        guard let sheet = window.attachedSheet else { return }
        window.endSheet(sheet, returnCode: .cancel)
    }

    func windowWillClose(_ notification: Notification) {
        pendingScanAction = nil
        cancelFilterHandoff()
    }

    func windowDidBecomeMain(_ notification: Notification) { render() }

    func windowDidResignKey(_ notification: Notification) { cancelFilterHandoff() }

    // MARK: Navigation

    func openScope(_ id: Int?) { session.navigate(to: id) }
    @objc func topLevelScope() { session.goToTopLevel() }
    @objc func up() { session.goUp() }
    @objc func previousPage() { session.previousPage() }
    @objc func nextPage() { session.nextPage() }

    @objc func drill() {
        guard !isAsking else { return }
        guard let row = controller.clickedOrSelectedRow(), ScopeNavigation.canOpen(row.node) else { return }
        session.navigate(to: row.node.id)
    }

    func selectionDidChange() {
        controller.showInspectorNotice("")
        window.toolbar?.validateVisibleItems()
        treemapEngagementMayHaveEnded()
        updateQuickLookSelection()
    }

    // MARK: Item actions

    private func selectedURL() -> URL? {
        guard !session.isLive, let result = session.result, let row = controller.selectedRow() else { return nil }
        return result.revealURL(for: row.node.id)
    }

    private func trashTarget(_ sender: Any?) -> TrashTarget? {
        if let item = sender as? NSMenuItem {
            guard let target = item.representedObject as? TrashTarget, canTrash(target) else { return nil }
            return target
        }
        return controller.selectedRow().flatMap { availableTrashTarget(for: $0.node.id) }
    }

    func availableTrashTarget(for node: Int) -> TrashTarget? {
        guard let target = session.result?.trashTarget(for: node), canTrash(target) else { return nil }
        return target
    }

    private func canTrash(_ target: TrashTarget) -> Bool {
        canStartScan && session.lastPlan != nil && session.result?.id == target.scanID
            && unavailableTrashTargets[target.url] != target.scanID
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard let target = trashTarget(sender), let plan = session.lastPlan else { return }
        trashAction = .confirming
        let alert = NSAlert()
        alert.messageText = "Move this file to the Trash?"
        alert.informativeText = target.url.path + "\n\nMoving to the Trash does not free disk space."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.layout()
        alert.window.defaultButtonCell = nil
        alert.buttons.forEach { $0.keyEquivalent = "" }
        alert.buttons[0].keyEquivalent = "\u{1b}"
        presentAlert(alert, window) { [weak self] response in
            guard let self, self.trashAction == .confirming else { return }
            self.trashAction = nil
            guard response == .alertSecondButtonReturn else {
                self.window.toolbar?.validateVisibleItems()
                return
            }
            self.performTrashMove(target, plan: plan)
        }
        window.toolbar?.validateVisibleItems()
    }

    private func performTrashMove(_ target: TrashTarget, plan: ScanPlan) {
        trashAction = .moving
        render()
        announce(StatusPresentation.movingToTrash.title)
        Task {
            let failure: (any Error)?
            do {
                guard !session.isLive, session.result?.id == target.scanID else {
                    throw TrashTarget.Failure.changed
                }
                try await ItemActions.moveToTrash(target, using: trashMover)
                failure = nil
            } catch {
                failure = error
            }
            reportTrashMove(target, plan: plan, failure: failure)
        }
    }

    private func reportTrashMove(_ target: TrashTarget, plan: ScanPlan, failure: (any Error)?) {
        trashAction = .reporting
        let stale = failure is TrashTarget.Failure
        if failure == nil || stale { unavailableTrashTargets[target.url] = target.scanID }
        let report = NSAlert()
        if let failure {
            report.messageText = "Couldn’t move file to Trash"
            report.informativeText = target.url.path + "\n\n" + failure.localizedDescription
            report.addButton(withTitle: stale ? "Cancel" : "OK")
            if stale { report.addButton(withTitle: "Refresh") }
        } else {
            report.messageText = "Moved to Trash"
            report.informativeText =
                target.url.path
                + "\n\nTo restore the file, open Trash in Finder, select the file, then choose File > Put Back."
            report.addButton(withTitle: "OK")
        }
        render()
        presentAlert(report, window) { [weak self] response in
            guard let self else { return }
            self.trashAction = nil
            if failure == nil || (stale && response == .alertSecondButtonReturn) {
                // Let the report sheet detach before a rescan can show a location refusal.
                self.afterScanSheet { app in
                    guard app.session.result?.id == target.scanID else { return }
                    app.refreshVolume()
                    app.session.start(plan)
                }
            }
            self.window.toolbar?.validateVisibleItems()
        }
    }

    var canCopyPath: Bool { selectedURL() != nil }

    private func selectedHandoffTarget() -> ItemHandoffTarget? {
        guard !session.isLive, let result = session.result, let row = controller.selectedRow() else { return nil }
        return ItemHandoffTarget(result: result, row: row)
    }

    var selectionOpenBehavior: OpenBehavior {
        selectedHandoffTarget().map { ItemOpenRule.open($0.menuFacts) } ?? .unavailable
    }

    private func updateQuickLookSelection() {
        guard quickLook.isShowing else { return }
        quickLook.selectionDidChange(to: selectedHandoffTarget())
    }

    @objc func openItem() {
        guard let target = selectedHandoffTarget() else { return }
        controller.showInspectorNotice("")
        if case .failure(let failure) = ItemActions.open(target) {
            showHandoffFailure(failure, target: target)
        }
    }

    /// Space and ⌘Y: shows or hides the Quick Look panel for the selection.
    @objc func toggleQuickLook() {
        if quickLook.isShowing {
            quickLook.close()
        } else if let target = selectedHandoffTarget() {
            controller.showInspectorNotice("")
            quickLook.show(target)
        }
    }

    private func showHandoffFailure(_ failure: ItemHandoffTarget.Failure, target: ItemHandoffTarget) {
        let notice = failure.notice(for: target.url.lastPathComponent)
        if !controller.inspectorVisible {
            controller.setInspectorVisible(true)
            window.toolbar?.validateVisibleItems()
        }
        controller.showInspectorNotice(notice)
        announce(notice)
    }

    @objc func copyPath() {
        guard let row = controller.selectedRow(), let path = session.displayPath(for: row.node.id),
            selectedURL() != nil
        else { return }
        ItemActions.copy(path: path)
    }

    @objc func showInFinder() {
        guard let url = selectedURL() else { return }
        if !ItemActions.reveal(url) {
            controller.showInspectorNotice(ProductCopy.Inspector.itemMissing(url.lastPathComponent))
        }
    }

    // MARK: Window panels and dialogs

    @objc func toggleList() { controller.toggleList() }
    @objc func resetSplit() { controller.resetSplit() }

    @objc func toggleInspector() {
        controller.setInspectorVisible(!controller.inspectorVisible)
        window.toolbar?.validateVisibleItems()
    }

    var canShowCoverage: Bool { commandState.canShowScanDetails }

    @objc func showCoverage() {
        guard !session.isLive, let coverage = session.result?.coverage else { return }
        Dialogs.showScanDetails(coverage)
    }

    @objc func showHelp() { Dialogs.showHelp() }
    @objc func showPrivacyPolicy() { Dialogs.showPrivacyPolicy() }

    // MARK: Quick Look panel control

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook.begin(panel) }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook.end(panel) }
    }

    // MARK: List filter and sort

    /// ⌘F: puts the cursor in the toolbar's filter field.
    @objc func focusFilter() {
        guard isEnabled(#selector(focusFilter)) else { return }
        if !window.isVisible || window.isMiniaturized { showWindow() }
        toolbar.focusFilter(in: window)
    }

    func filterDidChange(_ text: String) {
        guard listQuery.filter != text else { return }
        listQuery.filter = text
        filterScope = session.currentParent
        render()
    }

    /// Return or Down can defer the move until the current row query publishes.
    func filterDidFinish(from field: NSControl, editor: NSTextView) {
        guard field.currentEditor() === editor, window.firstResponder === editor else { return }
        // The field's search action may still be waiting to deliver the latest edit.
        filterDidChange(editor.string)
        let request = FilterHandoff(
            scope: session.scopeRequest, scanID: session.activeScanID ?? session.result?.id,
            query: listQuery, field: field, editor: editor)
        guard request.hasFocus(in: window) else { return }
        if controller.state.isPreparingRows {
            filterHandoff = request
        } else {
            cancelFilterHandoff()
            controller.focusListedRows()
        }
    }

    func cancelFilterHandoff() { filterHandoff = nil }

    private func completeFilterHandoff() {
        guard let request = filterHandoff else { return }
        guard request.scope == session.scopeRequest, request.scanID == (session.activeScanID ?? session.result?.id),
            request.query == listQuery, request.hasFocus(in: window)
        else {
            cancelFilterHandoff()
            return
        }
        guard !controller.state.isPreparingRows else { return }
        cancelFilterHandoff()
        controller.focusListedRows()
    }

    func listSortDidChange(_ sort: ListSort?) {
        listQuery.sort = sort ?? .standard
        render()
    }

    /// The rows the list shows: the session's, filtered and sorted. A filter belongs to the folder it was typed in.
    private func queriedRows(_ base: RowSource?) -> RowSource? {
        if listQuery.isFiltering, filterScope != .some(session.currentParent) || session.phase == .ready {
            listQuery.filter = ""
            toolbar.clearFilter()
        }
        return listQueryCache.requestRows(for: base, query: listQuery) { [weak self] in self?.render() }
    }

    // MARK: Availability

    /// The facts every command's availability is judged from, read now.
    var commandState: CommandState {
        let selectionCanOpen = controller.selectedRow().map { ScopeNavigation.canOpen($0.node) } ?? false
        let facts = selectedHandoffTarget()?.menuFacts
        return CommandState(
            phase: session.phase, isLive: session.isLive,
            isStopping: session.stopping, hasLastPlan: session.lastPlan != nil,
            hasResult: session.result != nil, selectionHasLocation: selectedURL() != nil,
            selectionCanOpen: selectionCanOpen, canGoUp: session.canGoUp,
            pageOffset: session.scopeRequest.offset,
            hasNextPage: session.requestedPage?.hasNext ?? false,
            selectionOpen: facts.map(ItemOpenRule.open) ?? .unavailable,
            selectionCanQuickLook: facts.map(ItemOpenRule.canQuickLook) ?? false)
    }

    /// One answer for the menu bar and the toolbar, so they cannot disagree.
    func isEnabled(_ action: Selector?) -> Bool {
        guard let command = AppCommand(action: action) else { return true }
        if !canStartScan, [.scanInternal, .scanFolder, .rescan].contains(command) { return false }
        return commandState.isEnabled(command)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(moveToTrash(_:)) { return trashTarget(menuItem) != nil }
        MainMenu.updateTitle(
            of: menuItem, inspectorShown: inspectorShown, listCollapsed: controller.listCollapsed,
            hasResult: session.result != nil)
        return isEnabled(menuItem.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.action == #selector(moveToTrash(_:)) { return trashTarget(item) != nil }
        return isEnabled(item.action)
    }

    // MARK: Storage map

    @objc func applyPendingTreemap() { session.applyPendingTreemap() }
    func treemapEngagementMayHaveEnded() { session.treemapEngagementMayHaveEnded() }

    // MARK: Rendering

    func render() {
        let screen = ScreenStateBuilder.build(session.screenInputs(volume: volumeContext))
        var state = screen.state
        if session.isValidating {
            state.status = StatusPresentation.checkingLocation(stopping: session.stopping)
        }
        if trashAction == .moving { state.status = StatusPresentation.movingToTrash }
        let listed = queriedRows(state.source)
        state.isFiltering = listQuery.isFiltering
        if listed == nil, state.source != nil {
            state.isPreparingRows = true
            state.empty = EmptyScope(
                symbol: "clock", title: ProductCopy.Waiting.orderingTitle,
                detail: ProductCopy.Waiting.orderingDetail)
        } else if listQuery.isFiltering, listed?.count == 0, (state.source?.count ?? 0) > 0 {
            let filter = ProductCopy.Filter.self
            state.empty = EmptyScope(
                symbol: "magnifyingglass", title: filter.noMatchesTitle,
                detail: filter.noMatchesDetail(listQuery.filterText, live: state.provisional))
        }
        state.source = listed
        let settled = session.isScanning ? nil : session.result
        state.itemCount = { id in settled?.itemCount(of: id) }
        state.inspect = { [weak self] row, presentation in
            guard let self else { return .empty }
            return InspectorContent.make(
                row: row, presentation: presentation, result: self.session.result,
                isLive: self.session.isScanning)
        }
        state.rowForNode = { [weak self] id in self?.session.rowForNode(id) }
        state.parentOf = { [weak self] id in self?.session.parentOfNode(id) }
        state.pathFor = { [weak self] id in self?.session.isScanning == false ? self?.session.displayPath(for: id) : nil
        }
        let hadSelection = controller.selectedNodeID != nil
        controller.render(state)
        if hadSelection, controller.selectedNodeID == nil { controller.showInspectorNotice("") }
        if quickLook.isShowing, controller.selectedRow() == nil { quickLook.close() }
        completeFilterHandoff()
        window.title = screen.windowTitle
        window.subtitle = screen.windowSubtitle
        window.defaultButtonCell = state.phase == .ready ? controller.scanButton.cell as? NSButtonCell : nil
        window.toolbar?.validateVisibleItems()
    }

    func announce(_ text: String) {
        guard let window else { return }
        NSAccessibility.post(
            element: window, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: ScanSessionDelegate

    func sessionNeedsRender() { render() }
    func sessionClearsSelection() {
        quickLook.close()
        controller.clearSelection()
        controller.showInspectorNotice("")
    }
    func sessionClearsNotice() { controller.showInspectorNotice("") }
    var sessionMapIsEngaged: Bool { controller.treemapEngaged }
    func sessionAnnounce(_ text: String) { announce(text) }

    func sessionScanWillStart() {
        if !window.isVisible { showWindow() }
    }

    func sessionScanWasRefused(_ result: ScanResult, plan: ScanPlan) {
        guard !closing, !quitting else { return }
        Dialogs.scanRefused(result, plan: plan, keptResults: session.result != nil, on: window) { [weak self] in
            self?.afterScanSheet { $0.scanFolder() }
        }
    }

    func sessionScanDidSettle() {
        unavailableTrashTargets = unavailableTrashTargets.filter { $0.value == session.result?.id }
        updateQuickLookSelection()
        if quitting { finishQuit(quitWait?.scanSettled()) }
        if closing {
            closing = false
            window.close()
        }
    }
}
