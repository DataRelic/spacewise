import SpacewiseAppModel
import SpacewiseCore
import Testing

@Suite struct ItemOpenRuleTests {
    private func item(
        _ kind: NodeKind = .file, _ classification: ContentClassification = .personal,
        issue: CoverageIssue? = nil, location: Bool = true, executable: Bool = false
    ) -> ItemFacts {
        ItemFacts(
            kind: kind, classification: classification, issue: issue, hasLocation: location,
            isExecutableFile: executable)
    }

    @Test func personalDocumentsFoldersAndPackagesOpen() {
        #expect(ItemOpenRule.open(item(.file)) == .open)
        #expect(ItemOpenRule.open(item(.directory)) == .open)
        #expect(ItemOpenRule.open(item(.package, .applicationManaged)) == .open)
        #expect(ItemOpenRule.open(item(.file, .developerManaged)) == .open)
    }

    @Test func systemManagedItemsAreOnlyShownInFinder() {
        for kind in [NodeKind.file, .directory, .package] {
            #expect(ItemOpenRule.open(item(kind, .systemManaged)) == .showInFinderOnly)
        }
    }

    @Test func executableFilesAreOnlyShownInFinder() {
        #expect(ItemOpenRule.open(item(.file, executable: true)) == .showInFinderOnly)
        // The execute bit on a folder only means it can be listed.
        #expect(ItemOpenRule.open(item(.directory, executable: true)) == .open)
    }

    @Test func linksSpecialItemsPlaceholdersAndUnreadItemsAreOnlyShownInFinder() {
        #expect(ItemOpenRule.open(item(.symbolicLink)) == .showInFinderOnly)
        #expect(ItemOpenRule.open(item(.other)) == .showInFinderOnly)
        #expect(ItemOpenRule.open(item(.file, issue: .placeholder)) == .showInFinderOnly)
        #expect(ItemOpenRule.open(item(.directory, issue: .denied)) == .showInFinderOnly)
    }

    @Test func nothingOpensWithoutALocation() {
        #expect(ItemOpenRule.open(item(.file, location: false)) == .unavailable)
        #expect(!ItemOpenRule.canQuickLook(item(.file, location: false)))
    }

    @Test func quickLookPreviewsSystemContentButNotLinksOrPlaceholders() {
        #expect(ItemOpenRule.canQuickLook(item(.file, .systemManaged)))
        #expect(ItemOpenRule.canQuickLook(item(.directory)))
        #expect(ItemOpenRule.canQuickLook(item(.file, executable: true)))
        #expect(!ItemOpenRule.canQuickLook(item(.symbolicLink)))
        #expect(!ItemOpenRule.canQuickLook(item(.file, issue: .placeholder)))
        #expect(!ItemOpenRule.canQuickLook(item(.directory, issue: .denied)))
    }
}
