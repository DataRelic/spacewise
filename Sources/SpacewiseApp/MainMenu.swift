import AppKit
import SpacewiseCore

/// The menu bar. Items are disabled, never hidden. Move to Trash is on the toolbar and the context menus only.
/// Items act on the app delegate unless they belong to the window or the focused view, which AppKit reaches through
/// the responder chain.
@MainActor enum MainMenu {
    private static func arrow(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code))!)) }

    /// Builds the menu bar and installs it, with the Services, Window and Help menus AppKit manages.
    static func install(target: AppDelegate) {
        let copy = ProductCopy.Menu.self
        let builder = Builder(target: target)
        let main = NSMenu()

        let app = builder.submenu(main, copy.app)
        builder.add(app, copy.about, #selector(AppDelegate.about))
        app.addItem(.separator())
        let services = NSMenuItem(title: copy.services, action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: copy.services)
        services.submenu = servicesMenu
        app.addItem(services)
        NSApp.servicesMenu = servicesMenu
        app.addItem(.separator())
        builder.add(app, copy.hide, #selector(NSApplication.hide(_:)), "h", target: NSApp)
        builder.add(
            app, copy.hideOthers, #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option],
            target: NSApp)
        builder.add(app, copy.showAll, #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        builder.add(app, copy.quit, #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        let added = ProductCopy.Commands.self
        let file = builder.submenu(main, copy.file)
        builder.add(file, copy.scanInternal, #selector(AppDelegate.scanInternal), "r")
        // ⌘O is Open, as in Finder; choosing a folder to scan takes ⇧⌘O.
        builder.add(file, copy.scanFolder, #selector(AppDelegate.scanFolder), "o", [.command, .shift])
        builder.add(file, copy.rescan, #selector(AppDelegate.rescan), "r", [.command, .option])
        builder.add(file, copy.stop, #selector(AppDelegate.cancel), ".")
        file.addItem(.separator())
        builder.add(file, added.open, #selector(AppDelegate.openItem), "o")
        builder.add(file, added.quickLook, #selector(AppDelegate.toggleQuickLook), "y")
        builder.add(file, copy.showInFinder, #selector(AppDelegate.showInFinder), "r", [.command, .shift])
        file.addItem(.separator())
        builder.add(file, copy.closeWindow, #selector(NSWindow.performClose(_:)), "w", responderChain: true)

        // Cut, Paste and Select All reach the filter field when it is being edited; the list and map have nothing to
        // cut or paste and select one item at a time, so the items are disabled there.
        let edit = builder.submenu(main, copy.edit)
        builder.add(edit, added.cut, #selector(NSText.cut(_:)), "x", responderChain: true)
        builder.add(edit, copy.copy, #selector(NSText.copy(_:)), "c", responderChain: true)
        builder.add(edit, added.paste, #selector(NSText.paste(_:)), "v", responderChain: true)
        builder.add(edit, added.selectAll, #selector(NSText.selectAll(_:)), "a", responderChain: true)
        edit.addItem(.separator())
        builder.add(edit, added.filter, #selector(AppDelegate.focusFilter), "f")

        let view = builder.submenu(main, copy.view)
        builder.add(view, copy.hideInspector, #selector(AppDelegate.toggleInspector), "i", [.command, .option])
        builder.add(view, copy.hideList, #selector(AppDelegate.toggleList), "l", [.command, .option])
        builder.add(view, copy.resetSplit, #selector(AppDelegate.resetSplit))
        view.addItem(.separator())
        builder.add(view, copy.scanDetails, #selector(AppDelegate.showCoverage), "d", [.command, .shift])
        view.addItem(.separator())
        // AppKit retitles this item "Exit Full Screen" while the window is in full screen.
        builder.add(
            view, added.enterFullScreen, #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control],
            responderChain: true)

        let go = builder.submenu(main, copy.go)
        builder.add(go, copy.enclosingFolder, #selector(AppDelegate.up), arrow(NSUpArrowFunctionKey))
        builder.add(go, copy.openFolder, #selector(AppDelegate.drill), arrow(NSDownArrowFunctionKey))
        builder.add(go, copy.topLevel, #selector(AppDelegate.topLevelScope), "c", [.command, .shift])
        go.addItem(.separator())
        builder.add(go, copy.previousPage, #selector(AppDelegate.previousPage), "[", [.command, .option])
        builder.add(go, copy.nextPage, #selector(AppDelegate.nextPage), "]", [.command, .option])

        let windowMenu = builder.submenu(main, copy.window)
        NSApp.windowsMenu = windowMenu
        builder.add(windowMenu, copy.minimize, #selector(NSWindow.performMiniaturize(_:)), "m", responderChain: true)
        builder.add(windowMenu, copy.zoom, #selector(NSWindow.performZoom(_:)), responderChain: true)
        windowMenu.addItem(.separator())
        builder.add(windowMenu, copy.bringAllToFront, #selector(NSApplication.arrangeInFront(_:)), target: NSApp)

        let help = builder.submenu(main, copy.help)
        NSApp.helpMenu = help
        builder.add(help, ProductCopy.helpTitle, #selector(AppDelegate.showHelp), "?")
        builder.add(help, ProductCopy.privacyPolicyTitle, #selector(AppDelegate.showPrivacyPolicy))
        NSApp.mainMenu = main
    }

    /// Items whose title says what they will do now.
    static func updateTitle(of item: NSMenuItem, inspectorShown: Bool, listCollapsed: Bool, hasResult: Bool) {
        let copy = ProductCopy.Menu.self
        switch item.action {
        case #selector(AppDelegate.toggleInspector):
            item.title = inspectorShown ? copy.hideInspector : copy.showInspector
        case #selector(AppDelegate.toggleList): item.title = listCollapsed ? copy.showList : copy.hideList
        case #selector(AppDelegate.scanInternal): item.title = hasResult ? copy.rescanInternal : copy.scanInternal
        default: break
        }
    }

    private struct Builder {
        let target: AppDelegate

        func add(
            _ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
            _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil, responderChain: Bool = false
        ) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
            // A nil target is what makes AppKit walk the responder chain; `target ?? self.target` would bind it to the
            // delegate.
            item.target = responderChain ? nil : (target ?? self.target)
            menu.addItem(item)
        }

        func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
    }
}
