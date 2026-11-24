import AppKit
import SpacewiseCore
import Testing

@testable import SpacewiseApp

@MainActor struct PrivacyPolicyTests {
    @Test func helpMenuOpensReadablePrivacyPolicy() throws {
        let application = NSApplication.shared
        let previousMenu = application.mainMenu
        let previousHelp = application.helpMenu
        let previousWindows = application.windowsMenu
        let previousServices = application.servicesMenu
        defer {
            application.mainMenu = previousMenu
            application.helpMenu = previousHelp
            application.windowsMenu = previousWindows
            application.servicesMenu = previousServices
        }

        let delegate = AppDelegate()
        MainMenu.install(target: delegate)
        let item = try #require(application.helpMenu?.item(withTitle: ProductCopy.privacyPolicyTitle))
        let action = try #require(item.action)
        #expect(item.target === delegate)
        #expect(delegate.validateMenuItem(item))
        #expect(application.sendAction(action, to: item.target, from: item))

        let window = try #require(application.windows.first { $0.title == ProductCopy.privacyPolicyTitle })
        defer { window.orderOut(nil) }
        let scrollView = try #require(window.contentView as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        #expect(window.isVisible)
        #expect(window.initialFirstResponder === textView)
        #expect(textView.accessibilityLabel() == ProductCopy.privacyPolicyTitle)
        #expect(textView.isEditable == false)
        #expect(textView.isSelectable)
        #expect(textView.string.contains("Scan results and paths stay in memory"))
        #expect(textView.string.contains("issue tracker at github.com/DataRelic/spacewise"))
    }
}
