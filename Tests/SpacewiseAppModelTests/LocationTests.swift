import Foundation
import SpacewiseAppModel
import SpacewiseCore
import SpacewiseFixtures
import Testing

@Suite struct LocationTests {
    @Test func theUnifiedDriveShowsDataVolumePathsRootedAtSlash() throws {
        let result = PresentationFixtures.wholeDrive()
        let cache = try #require(result.nodes.first { $0.name == "dyld-shared-cache" })
        #expect(result.displayPath(for: cache.id) == "/System/Library/dyld-shared-cache")
    }

    @Test func aFolderScanShowsRealPaths() throws {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let docker = try #require(result.nodes.first { $0.name == "Docker.raw" })
        #expect(result.displayPath(for: docker.id) == result.url(for: docker.id)?.path)
        #expect(result.revealURL(for: docker.id) == result.url(for: docker.id))
    }

    @Test func aMergedFolderIsRevealedAtItsLogicalPath() throws {
        let result = PresentationFixtures.wholeDrive()
        let group = LogicalNamespace.managedGroupID
        let system = try #require(
            result.namespace.list(for: group)?.first { result.logicalNode(for: $0)?.name == "System" })
        #expect(result.namespace.isMerged(system))
        let path = try #require(result.displayPath(for: system))
        #expect(result.revealURL(for: system) == URL(fileURLWithPath: path))
    }

    @Test func anUnknownNodeHasNoLocation() {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        #expect(result.displayPath(for: result.nodes.count + 5) == nil)
        #expect(result.revealURL(for: result.nodes.count + 5) == nil)
    }
}

@Suite struct InspectorContentTests {
    private func content(_ name: String, in result: ScanResult, isLive: Bool = false) throws -> InspectorContent {
        let node = try #require(result.nodes.first { $0.name == name })
        let row = try #require(result.logicalRow(for: node.id))
        let presentation = RowPresentation(
            row: row, provisional: isLive, scopeAllocated: result.progress.allocatedBytes)
        return InspectorContent.make(row: row, presentation: presentation, result: result, isLive: isLive)
    }

    @Test func aSettledFolderScanItemHasItsPathAndCanBeRevealed() throws {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let shown = try content("Docker.raw", in: result)
        #expect(shown.canReveal)
        let location = try #require(shown.fields.first { $0.role == .location })
        #expect(location.value == result.url(for: result.nodes.first { $0.name == "Docker.raw" }!.id)?.path)
        #expect(!shown.fields.contains { $0.label == ProductCopy.Inspector.physicalLocationLabel })
    }

    @Test func whileScanningNothingHasALocation() throws {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let shown = try content("Docker.raw", in: result, isLive: true)
        #expect(!shown.canReveal)
        #expect(!shown.fields.contains { $0.role == .location })
        #expect(shown.notes.contains { $0.label == ProductCopy.InspectorFields.aboutScanning })
    }

    @Test func fieldsAreShortAndExplanationsWaitBehindTheDisclosure() throws {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let shown = try content("Docker.raw", in: result)
        let copy = ProductCopy.InspectorFields.self
        let labels = shown.fields.map(\.label)
        #expect(Array(labels.prefix(2)) == [copy.kind, copy.size])
        #expect(labels.contains(copy.coverage) && labels.contains(copy.classification))
        // Every value but a path is a few words; the sentences live in the notes.
        for field in shown.fields where field.role == .detail {
            #expect(field.value.count <= 40, "\(field.label): \(field.value)")
        }
        let notes = shown.notes.map(\.label)
        #expect(notes.contains(copy.aboutCoverage) && notes.contains(copy.aboutClassification))
        #expect(shown.notes.allSatisfy { !$0.value.isEmpty })
    }

    @Test func aFolderShowsHowManyItemsItHolds() throws {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let folder = try #require(result.nodes.first { $0.name == "Users" })
        let shown = try content("Users", in: result)
        let items = try #require(shown.fields.first { $0.label == ProductCopy.InspectorFields.items })
        #expect(items.value == SizeFormat.count(UInt64(result.itemCount(of: folder.id) ?? -1)))
        let file = try content("Docker.raw", in: result)
        #expect(!file.fields.contains { $0.label == ProductCopy.InspectorFields.items })
    }

    @Test func theManagedGroupExplainsItselfInsteadOfAPath() throws {
        let result = PresentationFixtures.wholeDrive()
        let group = LogicalNamespace.managedGroupID
        let row = try #require(result.logicalRow(for: group))
        let presentation = RowPresentation(row: row, provisional: false, scopeAllocated: result.progress.allocatedBytes)
        let shown = InspectorContent.make(row: row, presentation: presentation, result: result, isLive: false)
        let copy = ProductCopy.Inspector.self
        let labels = shown.fields.map(\.label)
        #expect(!shown.fields.contains { $0.role == .location })
        #expect(Array(labels.suffix(2)) == [ProductCopy.InspectorFields.measured, copy.physicalLocationsLabel])
        #expect(shown.notes.first { $0.role == .location }?.value == copy.managedGroupLocation)
        let notes = shown.notes.map(\.label)
        #expect(
            Array(notes.prefix(4)) == [
                copy.whatThisIsLabel, ProductCopy.InspectorFields.location, copy.measuredLabel, copy.notMeasuredLabel,
            ])
        let measured = try #require(shown.notes.first { $0.label == copy.measuredLabel })
        let endings = [copy.managedGroupLowerBoundEnding, copy.managedGroupExactEnding]
        #expect(endings.contains { measured.value.hasSuffix($0) })
    }

    @Test func aMergedFolderListsBothPhysicalLocations() throws {
        let result = PresentationFixtures.wholeDrive()
        let group = LogicalNamespace.managedGroupID
        let system = try #require(
            result.namespace.list(for: group)?.first { result.logicalNode(for: $0)?.name == "System" })
        let row = try #require(result.logicalRow(for: system))
        let presentation = RowPresentation(row: row, provisional: false, scopeAllocated: result.progress.allocatedBytes)
        let shown = InspectorContent.make(row: row, presentation: presentation, result: result, isLive: false)
        let both = try #require(shown.fields.first { $0.label == ProductCopy.Inspector.storedOnBothVolumesLabel })
        #expect(both.value.split(separator: "\n").count == 2)
    }

    @Test func anItemWhosePathIsItsLocationGetsNoExtraField() throws {
        let result = PresentationFixtures.wholeDrive()
        let cache = try #require(result.nodes.first { $0.name == "dyld-shared-cache" })
        let row = try #require(result.logicalRow(for: cache.id))
        let presentation = RowPresentation(row: row, provisional: false, scopeAllocated: result.progress.allocatedBytes)
        let shown = InspectorContent.make(row: row, presentation: presentation, result: result, isLive: false)
        let physical = result.physicalPaths(for: cache.id)
        let expectsField = physical.count > 1 || physical.first != result.displayPath(for: cache.id)
        let labels = [ProductCopy.Inspector.physicalLocationLabel, ProductCopy.Inspector.storedOnBothVolumesLabel]
        #expect(shown.fields.contains { labels.contains($0.label) } == expectsField)
        #expect(shown.canReveal)
    }
}
