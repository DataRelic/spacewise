import AppKit
import SpacewiseAppModel
import SpacewiseCore

/// Builds the one main window around its content controller and toolbar.
@MainActor enum MainWindow {
    static func make(
        controller: MainViewController, delegate: NSWindowDelegate,
        toolbarDelegate: NSToolbarDelegate
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowLayout.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = ProductCopy.App.name
        window.minSize = WindowLayout.minimumSize
        // The one main window can fill the screen (View > Enter Full Screen, ⌃⌘F).
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Read before the autosave name is set, which can store the current frame.
        let savedFrame = UserDefaults.standard.object(forKey: WindowLayout.savedFrameKey)
        let initialFrame = WindowLayout.initialFrame(savedFrame: savedFrame)
        window.delegate = delegate
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(WindowLayout.autosaveName)
        window.toolbarStyle = .unified
        window.contentViewController = controller
        controller.loadViewIfNeeded()
        controller.connectActions()
        let toolbar = NSToolbar(identifier: "SpacewiseToolbar")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        switch initialFrame {
        case .restoreSaved(let name):
            // Installing the content controller and toolbar resizes the window; put the user's frame back. Should AppKit
            // still refuse it, start as on a first launch rather than wherever the window happens to be.
            if !window.setFrameUsingName(name) { center(window) }
        case .centered:
            center(window)
        }
        return window
    }

    private static func center(_ window: NSWindow) {
        window.setContentSize(WindowLayout.defaultContentSize)
        window.center()
    }
}
