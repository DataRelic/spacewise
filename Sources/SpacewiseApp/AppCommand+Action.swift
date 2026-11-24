import AppKit
import SpacewiseAppModel

extension AppCommand {
    /// The command a menu or toolbar action stands for; nil for actions that are always available.
    @MainActor init?(action: Selector?) {
        switch action {
        case #selector(AppDelegate.scanInternal): self = .scanInternal
        case #selector(AppDelegate.scanFolder): self = .scanFolder
        case #selector(AppDelegate.rescan): self = .rescan
        case #selector(AppDelegate.cancel): self = .stopScan
        case #selector(AppDelegate.showInFinder), #selector(AppDelegate.copyPath): self = .showInFinder
        case #selector(AppDelegate.openItem): self = .openItem
        case #selector(AppDelegate.toggleQuickLook): self = .quickLook
        case #selector(AppDelegate.focusFilter): self = .filterList
        case #selector(AppDelegate.toggleInspector): self = .toggleInspector
        case #selector(AppDelegate.toggleList): self = .toggleList
        case #selector(AppDelegate.resetSplit): self = .resetSplit
        case #selector(AppDelegate.showCoverage): self = .showScanDetails
        case #selector(AppDelegate.up): self = .enclosingFolder
        case #selector(AppDelegate.drill): self = .openFolder
        case #selector(AppDelegate.topLevelScope): self = .topLevel
        case #selector(AppDelegate.previousPage): self = .previousPage
        case #selector(AppDelegate.nextPage): self = .nextPage
        default: return nil
        }
    }
}
