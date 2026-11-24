import AppKit
import SpacewiseCore

/// A question the person must answer before the app goes on.
enum Confirmation {
    /// Starting a scan discards the results on screen.
    case replaceResults
    case closeDuringScan
    case quitDuringScan
}

/// Every question, panel and text window the app shows. Questions are sheets on the main window, so the rest of the
/// app keeps running and the answer arrives in a completion handler; text windows are ordinary windows.
@MainActor enum Dialogs {
    typealias FolderSelection = @MainActor (URL?) -> Void
    typealias FolderPicker = @MainActor (NSWindow, @escaping FolderSelection) -> Void
    typealias AlertResponse = @MainActor (NSApplication.ModalResponse) -> Void
    typealias AlertPresenter = @MainActor (NSAlert, NSWindow, @escaping AlertResponse) -> Void

    static func presentAlert(_ alert: NSAlert, on window: NSWindow, completion: @escaping AlertResponse) {
        alert.beginSheetModal(for: window, completionHandler: completion)
    }

    /// Asks for a folder to scan in a sheet on `window`. `completion` receives the folder, or nil if the person cancelled.
    static func chooseFolder(on window: NSWindow, completion: @escaping FolderSelection) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = ProductCopy.Dialog.chooseFolderMessage
        panel.prompt = ProductCopy.Dialog.chooseFolderPrompt
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    static func confirmationAlert(_ question: Confirmation) -> NSAlert {
        let copy = ProductCopy.Dialog.self
        let alert = NSAlert()
        switch question {
        case .replaceResults:
            alert.messageText = copy.replaceTitle
            alert.informativeText = copy.replaceDetail
            alert.addButton(withTitle: copy.replaceCancel)
            alert.addButton(withTitle: copy.replaceConfirm)
        case .closeDuringScan:
            alert.messageText = copy.closeDuringScanTitle
            alert.informativeText = copy.closeDuringScanDetail
            alert.addButton(withTitle: copy.keepScanning)
            alert.addButton(withTitle: copy.closeDuringScanConfirm)
        case .quitDuringScan:
            alert.messageText = copy.quitDuringScanTitle
            alert.informativeText = copy.quitDuringScanDetail
            alert.addButton(withTitle: copy.keepScanning)
            alert.addButton(withTitle: copy.quitDuringScanConfirm)
        }
        // The first button is the safe answer, so it is the default (Return). AppKit gives a "Cancel" button Escape.
        return alert
    }

    static func scanRefused(
        _ result: ScanResult, plan: ScanPlan, keptResults: Bool, on window: NSWindow,
        chooseAgain: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = plan.startup ? "Couldn’t scan the startup disk" : "Couldn’t scan the selected folder"
        let location = plan.roots.first?.path
        let reason =
            PresentationLabels.selectedRootRefusal(result.coverage)
            ?? result.coverage.records.first.map {
                $0.policyDetail ?? PresentationLabels.issue($0.reason)
            }
        alert.informativeText = [
            plan.startup ? nil : location,
            reason.map { "Reason — \($0)" },
            keptResults ? "Your previous results are still available." : nil,
        ].compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: "Close").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Choose Another Folder…")
        alert.addButton(withTitle: ProductCopy.Dialog.scanDetailsTitle)
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { chooseAgain() }
            if response == .alertThirdButtonReturn { showScanDetails(result.coverage) }
        }
    }

    /// Hand off to System Settings without changing access. If the URL cannot be opened, show the manual route.
    static func openFullDiskAccessSettings(
        on window: NSWindow, open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        guard !open(pane) else { return }

        let alert = NSAlert()
        alert.messageText = "Couldn’t open Full Disk Access settings"
        alert.informativeText = "\(ScanDetails.accessRecovery)\n\n\(ScanDetails.rescanAfterAccess)"
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private static let privacyPolicy = TextWindow(autosaveName: "SpacewisePrivacyPolicy")
    private static let help = TextWindow(autosaveName: "SpacewiseHelp")
    private static let scanDetails = TextWindow(autosaveName: "SpacewiseScanDetails")

    /// What was left unread and why, followed by the recorded locations. One window, refreshed each time it is shown.
    static func showScanDetails(_ coverage: LocationCoverage) {
        let copy = ProductCopy.Dialog.self
        var blocks = TextBlock.parse(ScanDetails.make(coverage).text)
        if !coverage.records.isEmpty {
            blocks += [.heading(copy.recordedPathsTitle), .paragraph(copy.recordedPathsSummary)]
            blocks += TextBlock.parse(ScanDetails.paths(coverage), subheadings: true)
        }
        scanDetails.show(title: copy.scanDetailsTitle, summary: nil, blocks: blocks)
    }

    static func showHelp() {
        help.show(
            title: ProductCopy.helpTitle, summary: ProductCopy.Dialog.helpSummary,
            blocks: TextBlock.parse(ProductCopy.helpBody))
    }

    static func showPrivacyPolicy() {
        privacyPolicy.show(
            title: ProductCopy.privacyPolicyTitle, summary: nil,
            blocks: TextBlock.parse(ProductCopy.privacyPolicyBody))
    }

    /// The version comes from the app bundle, so the About panel always matches the build that is running.
    static func showAbout(identity: String) {
        let credits = NSAttributedString(
            string: ProductCopy.App.aboutCredits,
            attributes: [
                .font: Typography.secondary, .foregroundColor: NSColor.labelColor,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: aboutVersion(bundle: Bundle.main, identity: identity),
            .version: "",
            .credits: credits,
        ])
    }

    /// "0.1 (42)" from the bundle's `CFBundleShortVersionString` and build, or the development wording when the app
    /// runs straight from the build folder and has no Info.plist to read.
    static func aboutVersion(bundle: Bundle, identity: String) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let short, !short.isEmpty else { return "\(ProductCopy.About.unbundledVersion) (\(identity))" }
        return "\(short) (\(identity))"
    }
}

/// One block of a text window: a section heading, a paragraph, a list item, or a gap.
enum TextBlock: Equatable {
    case heading(String)
    case subheading(String)
    case paragraph(String)
    case bullet(String)

    /// Reads plain text into blocks. Paragraphs are separated by blank lines. A line in capitals, or a single short
    /// line with no closing punctuation, is a heading; "• " starts a list item.
    static func parse(_ text: String, subheadings: Bool = false) -> [TextBlock] {
        var blocks: [TextBlock] = []
        for chunk in text.components(separatedBy: "\n\n") {
            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var paragraph: [String] = []
            func flush() {
                if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
                paragraph = []
            }
            for line in lines {
                if line.hasPrefix("• ") {
                    flush()
                    blocks.append(.bullet(String(line.dropFirst(2))))
                } else if isHeading(line, alone: lines.count == 1) {
                    flush()
                    let title = sentenceCase(line)
                    blocks.append(subheadings ? .subheading(title) : .heading(title))
                } else if subheadings {
                    // Recorded paths: one location per line.
                    flush()
                    blocks.append(.bullet(line))
                } else {
                    paragraph.append(line)
                }
            }
            flush()
        }
        return blocks
    }

    private static func isHeading(_ line: String, alone: Bool) -> Bool {
        let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if !letters.isEmpty, line == line.uppercased(), letters.count > 2 { return true }
        guard alone, line.count <= 48, let last = line.last else { return false }
        return !".:;!?…)”\"".contains(last)
    }

    private static func sentenceCase(_ line: String) -> String {
        guard line == line.uppercased() else { return line }
        let lower = line.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }
}

/// A titled, resizable window of readable text in sections. One instance per kind; showing it again brings it forward
/// with fresh content. ⌘W and Escape close it.
@MainActor final class TextWindow: NSObject, NSWindowDelegate {
    private let autosaveName: String
    private var window: TextPanelWindow?
    private let textView = TextPanelTextView()

    init(autosaveName: String) {
        self.autosaveName = autosaveName
    }

    func show(title: String, summary: String?, blocks: [TextBlock]) {
        let window = self.window ?? makeWindow()
        self.window = window
        window.title = title
        textView.setAccessibilityLabel(title)
        textView.textStorage?.setAttributedString(Self.render(summary: summary, blocks: blocks))
        textView.scrollToBeginningOfDocument(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> TextPanelWindow {
        let window = TextPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 280)
        window.delegate = self
        window.collectionBehavior = [.fullScreenNone]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: Spacing.xl, height: Spacing.l)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.documentView = textView
        window.contentView = scroll
        window.initialFirstResponder = textView
        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
        return window
    }

    private static func render(summary: String?, blocks: [TextBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func style(spacingBefore: CGFloat, indent: CGFloat = 0) -> NSMutableParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = spacingBefore
            paragraph.paragraphSpacing = Spacing.xs
            paragraph.lineSpacing = 2
            // A list item's marker sits at the margin; its text and wrapped lines align at the indent.
            paragraph.headIndent = indent
            if indent > 0 { paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)] }
            return paragraph
        }
        func append(_ text: String, font: NSFont, color: NSColor = .labelColor, paragraph: NSParagraphStyle) {
            let leading = out.length == 0 ? "" : "\n"
            out.append(
                NSAttributedString(
                    string: leading + text,
                    attributes: [
                        .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
                    ]))
        }
        if let summary {
            append(summary, font: Typography.body, color: .secondaryLabelColor, paragraph: style(spacingBefore: 0))
        }
        for block in blocks {
            switch block {
            case .heading(let text):
                append(text, font: Typography.heading, paragraph: style(spacingBefore: out.length == 0 ? 0 : Spacing.l))
            case .subheading(let text):
                append(text, font: Typography.heading, paragraph: style(spacingBefore: Spacing.m))
            case .paragraph(let text):
                append(text, font: Typography.body, paragraph: style(spacingBefore: Spacing.s))
            case .bullet(let text):
                append(
                    "•\t" + text, font: Typography.body, paragraph: style(spacingBefore: Spacing.xs, indent: Spacing.l))
            }
        }
        return out
    }
}

/// Escape closes a text window, as it would a panel.
final class TextPanelWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// A read-only text view hands Escape to its window (a text view would otherwise offer completions).
final class TextPanelTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.escape {
            window?.cancelOperation(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
