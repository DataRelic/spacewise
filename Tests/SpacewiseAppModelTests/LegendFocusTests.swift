import SpacewiseAppModel
import SpacewiseCore
import SpacewiseFixtures
import Testing

@Suite struct LegendFocusTests {
    @Test func theManagedEntryLightsExactlyTheManagedTiles() {
        let model = PresentationFixtures.wholeDrive().treemap(parent: nil)
        #expect(model.tiles.contains { $0.managed })
        for tile in model.tiles {
            #expect(LegendFocus.matches(tile, .managedZone) == tile.managed)
        }
    }

    @Test func aFileTypeNeverLightsManagedTiles() {
        let model = PresentationFixtures.wholeDrive().treemap(parent: nil)
        for tile in model.tiles where tile.managed {
            #expect(!LegendFocus.matches(tile, tile.category))
        }
    }

    @Test func aFileTypeLightsItsOwnTilesAndTheBlocksItTints() {
        let model = PresentationFixtures.storageMap(tailFiles: 200).treemap(parent: 0)
        for tile in model.tiles where !tile.managed {
            #expect(LegendFocus.matches(tile, tile.category))
            if let tint = tile.tint { #expect(LegendFocus.matches(tile, tint)) }
        }
    }

    @Test func aFileTypeLeavesOtherTypesDark() throws {
        let model = PresentationFixtures.storageMap(tailFiles: 200).treemap(parent: 0)
        let video = try #require(model.tiles.first { !$0.managed && $0.category == .video && $0.tint == nil })
        #expect(!LegendFocus.matches(video, .images))
    }
}
