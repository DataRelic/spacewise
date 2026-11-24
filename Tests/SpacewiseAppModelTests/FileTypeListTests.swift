import SpacewiseAppModel
import SpacewiseCore
import SpacewiseFixtures
import Testing

@Suite struct FileTypeListTests {
    @Test func rowsAreLargestFirstAndSharesAddUpToTheWholeMap() throws {
        for model in [
            PresentationFixtures.storageMap(tailFiles: 800).treemap(parent: 0),
            PresentationFixtures.wholeDrive().treemap(parent: nil),
            PresentationFixtures.studio().treemap(parent: 0),
        ] {
            let rows = FileTypeList.rows(for: model)
            #expect(rows.count >= 6)
            for (earlier, later) in zip(rows, rows.dropFirst()) { #expect(earlier.bytes >= later.bytes) }
            #expect(rows.reduce(UInt64(0)) { $0 + $1.bytes } == model.rootWeight)
            let shares = rows.reduce(0.0) { $0 + $1.share }
            #expect(abs(shares - 1) < 1e-9)
            for row in rows { #expect(row.share > 0 && row.share <= 1 && row.items > 0) }
            #expect(Set(rows.map(\.category)).count == rows.count)
        }
    }

    @Test func countsMatchTheTilesTheRowLightsUp() throws {
        let model = PresentationFixtures.studio().treemap(parent: 0)
        for row in FileTypeList.rows(for: model) where row.category != .managedZone {
            let leaves = model.tiles.dropFirst().filter { $0.isLeaf && !$0.managed && $0.category == row.category }
            let items = leaves.reduce(0) { $0 + ($1.kind == .aggregate ? $1.itemCount : 1) }
            #expect(row.items == items, "\(row.category.title)")
            #expect(row.bytes == leaves.reduce(UInt64(0)) { $0 + $1.weight })
        }
    }

    @Test func managedTilesHaveOneRowOfTheirOwn() throws {
        let model = PresentationFixtures.wholeDrive().treemap(parent: nil)
        let rows = FileTypeList.rows(for: model)
        let managed = try #require(rows.first { $0.category == .managedZone })
        let tiles = model.tiles.dropFirst().filter { $0.isLeaf && $0.managed }
        #expect(managed.bytes == tiles.reduce(UInt64(0)) { $0 + $1.weight })
    }

    @Test func noMapMeansNoRows() {
        #expect(FileTypeList.rows(for: nil).isEmpty)
        let empty = PresentationFixtures.scenario(.empty).result.treemap(parent: 0)
        #expect(FileTypeList.rows(for: empty).isEmpty)
    }

    @Test func choosingTheHighlightedTypeAgainClearsIt() {
        var highlight = TypeHighlight()
        highlight.choose(.video)
        #expect(highlight.category == .video)
        highlight.choose(.images)
        #expect(highlight.category == .images)
        highlight.choose(.images)
        #expect(highlight.category == nil)
        highlight.choose(.audio)
        highlight.clear()
        #expect(highlight.category == nil)
        highlight.choose(nil)
        #expect(highlight.category == nil)
    }

    @Test func aHighlightTheNewMapCannotShowIsDropped() {
        let rows = FileTypeList.rows(for: PresentationFixtures.storageMap(tailFiles: 200).treemap(parent: 0))
        var highlight = TypeHighlight(.video)
        let keptVideo = !highlight.keep(only: rows)
        #expect(keptVideo && highlight.category == .video)
        highlight = TypeHighlight(.managedZone)
        let droppedManaged = highlight.keep(only: rows)
        #expect(droppedManaged && highlight.category == nil)
        var none = TypeHighlight()
        let noneChanged = none.keep(only: rows)
        #expect(!noneChanged)
    }
}

@Suite struct MapContinuityTests {
    @Test func aMapContinuesWithinAScanAndIntoItsResultButNotAcrossScans() {
        #expect(MapContinuity.continues(from: .settled, to: .settled))
        #expect(MapContinuity.continues(from: .scanning, to: .scanning))
        #expect(MapContinuity.continues(from: .scanning, to: .stopping))
        #expect(MapContinuity.continues(from: .stopping, to: .settled))
        #expect(MapContinuity.continues(from: .scanning, to: .settled))
        #expect(!MapContinuity.continues(from: .settled, to: .scanning))
        #expect(!MapContinuity.continues(from: .settled, to: .ready))
        #expect(!MapContinuity.continues(from: .ready, to: .scanning))
    }
}
