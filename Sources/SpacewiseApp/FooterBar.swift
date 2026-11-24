import AppKit
import SpacewiseAppModel
import SpacewiseCore

/// The line under the results while a live scan pages its rows: the page buttons and counts for this page.
/// The window hides it when there is only one page.
final class FooterBar: NSStackView {
    let previousButton = NSButton()
    let nextButton = NSButton()
    private let pageLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let pages = [
            (previousButton, "chevron.left", ProductCopy.List.previousPage),
            (nextButton, "chevron.right", ProductCopy.List.nextPage),
        ]
        for (button, name, label) in pages {
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: label)
            button.bezelStyle = .texturedRounded
            button.isBordered = true
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
        pageLabel.font = Typography.numericSecondary
        pageLabel.textColor = .secondaryLabelColor
        setViews([previousButton, nextButton, pageLabel], in: .leading)
        orientation = .horizontal
        alignment = .centerY
        spacing = Spacing.s
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func render(_ state: ScreenState) {
        previousButton.isEnabled = state.canGoPrevious
        nextButton.isEnabled = state.canGoNext
        pageLabel.stringValue =
            state.livePage.map { page in
                ProductCopy.List.livePage(
                    page.offset / ScopeSnapshot.pageSize + 1, entries: state.summary == nil ? nil : page.shown,
                    matches: state.isFiltering ? state.source?.count : nil)
            } ?? ""
    }
}
