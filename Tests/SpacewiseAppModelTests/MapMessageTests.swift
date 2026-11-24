import SpacewiseAppModel
import SpacewiseCore
import SpacewiseFixtures
import Testing

@Suite struct MapMessageTests {
    @Test func theReadyScreenHasNoMapMessage() {
        #expect(MapMessage.make(phase: .ready, model: nil, isLive: false) == nil)
    }

    @Test func aLiveScanWaitsForItsFirstMap() {
        let message = MapMessage.make(phase: .scanning, model: nil, isLive: true)
        #expect(message?.title == ProductCopy.Map.waitingTitle)
        #expect(message?.symbol == "clock")
    }

    @Test func aSettledScopeSaysItsMapIsBeingBuilt() {
        let message = MapMessage.make(phase: .settled, model: nil, isLive: false)
        #expect(message?.title == ProductCopy.Map.buildingTitle)
    }

    @Test func aMapWithTilesNeedsNoMessage() async throws {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let model = await TreemapBuilder.build(result: result, parent: 0)
        try #require(!model.isEmpty)
        #expect(MapMessage.make(phase: .settled, model: model, isLive: false) == nil)
    }

    @Test func anEmptySettledFolderHasNothingToDraw() async throws {
        let result = PresentationFixtures.scenario(.empty).result
        let model = await TreemapBuilder.build(result: result, parent: 0)
        try #require(model.isEmpty && !model.provisional)
        let message = MapMessage.make(phase: .settled, model: model, isLive: false)
        #expect(message?.title == ProductCopy.Map.nothingToDrawTitle)
        #expect(message?.symbol == "square.dashed")
    }

    @Test func aLiveMapWithTilesNeedsNoMessage() throws {
        let model = try #require(PresentationFixtures.scenario(.scanning).snapshot.treemap)
        try #require(model.provisional && !model.isEmpty)
        #expect(MapMessage.make(phase: .scanning, model: model, isLive: true) == nil)
    }
}
