import CoreGraphics
import SpacewiseFixtures
import Testing

@testable import SpacewiseCore

struct TreemapRasterCancellationTests {
    private let width = 8
    private let height = 65
    private let sentinel: UInt8 = 0xA5
    private let scan = PresentationFixtures.scenario(.complete).result

    private var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    @Test func cancelledBackdropLeavesUntouchedRows() {
        let model = PresentationFixtures.scenario(.empty).result.treemap(parent: 0)
        let layout = TreemapLayout.compute(model, in: bounds)
        let rowBytes = width * 4
        var buffer = [UInt8](repeating: sentinel, count: height * rowBytes)
        var checks = 0
        let finished = buffer.withUnsafeMutableBufferPointer {
            TreemapRaster.renderIfNotCancelled(
                model: model, layout: layout, into: $0, pixelWidth: width, pixelHeight: height, scale: 1,
                isCancelled: {
                    checks += 1
                    return checks >= 2
                })
        }
        #expect(!finished)
        let drawnRows = buffer.prefix(while: { $0 != sentinel }).count / rowBytes
        #expect(drawnRows > 0 && drawnRows <= 16)
        #expect(buffer.dropFirst(drawnRows * rowBytes).allSatisfy { $0 == sentinel })
    }

    @Test func cancellationStopsInsideOneLargeTile() throws {
        let model = scan.treemap(parent: 0, limits: TreemapLimits(maxTiles: 2))
        let layout = TreemapLayout.compute(model, in: bounds)
        try #require(model.tiles.count == 2 && model.tiles[1].isLeaf && layout.rects[1] == bounds)
        let shaded = TreemapRaster.render(
            model: model, layout: layout, pixelWidth: width, pixelHeight: height, scale: 1)
        let backdrop = TreemapRaster.render(
            model: model, layout: layout, pixelWidth: width, pixelHeight: height, scale: 1,
            isCancelled: { true })
        var buffer = backdrop
        var checks = 0
        let finished = buffer.withUnsafeMutableBufferPointer {
            TreemapRaster.renderIfNotCancelled(
                model: model, layout: layout, into: $0, pixelWidth: width, pixelHeight: height, scale: 1,
                isCancelled: {
                    checks += 1
                    // Five backdrop blocks, the root's tile check, then allow the leaf's first block.
                    return checks >= 8
                })
        }
        #expect(!finished)
        let firstBlock = 16 * width * 4
        #expect(buffer != backdrop)
        #expect(buffer.prefix(firstBlock) == shaded.prefix(firstBlock))
        #expect(buffer.dropFirst(firstBlock) == backdrop.dropFirst(firstBlock))
    }

    @Test func cancelChecksAlsoRunForSkippedTiles() throws {
        let model = scan.treemap(parent: 0)
        try #require(model.tiles.count > 64)
        let layout = TreemapLayout(bounds: bounds, rects: Array(repeating: .zero, count: model.tiles.count))
        var buffer = [UInt8](repeating: sentinel, count: 4)
        var checks = 0
        let finished = buffer.withUnsafeMutableBufferPointer {
            TreemapRaster.renderIfNotCancelled(
                model: model, layout: layout, into: $0, pixelWidth: 1, pixelHeight: 1, scale: 1,
                isCancelled: {
                    checks += 1
                    return checks >= 3
                })
        }
        #expect(!finished)
        #expect(checks == 3)
        #expect(buffer[3] == 255)
    }

    @Test func arrayAndLegacyBufferStayInitializedAndCompletedRasterMatches() {
        let model = scan.treemap(parent: 0)
        let layout = TreemapLayout.compute(model, in: bounds)
        let array = TreemapRaster.render(
            model: model, layout: layout, pixelWidth: width, pixelHeight: height, scale: 1,
            isCancelled: { true })
        let empty = PresentationFixtures.scenario(.empty).result.treemap(parent: 0)
        let backdrop = TreemapRaster.render(
            model: empty, layout: TreemapLayout.compute(empty, in: bounds),
            pixelWidth: width, pixelHeight: height, scale: 1)
        #expect(array == backdrop)
        var buffer = [UInt8](repeating: sentinel, count: width * height * 4 + 4)
        buffer.withUnsafeMutableBufferPointer {
            TreemapRaster.render(
                model: model, layout: layout, into: $0, pixelWidth: width, pixelHeight: height, scale: 1,
                isCancelled: { true })
        }
        #expect(buffer.dropLast(4).elementsEqual(backdrop))

        let finished = buffer.withUnsafeMutableBufferPointer {
            TreemapRaster.renderIfNotCancelled(
                model: model, layout: layout, into: $0, pixelWidth: width, pixelHeight: height, scale: 1,
                isCancelled: { false })
        }
        #expect(finished)
        #expect(
            buffer.dropLast(4).elementsEqual(
                TreemapRaster.render(model: model, layout: layout, pixelWidth: width, pixelHeight: height, scale: 1)))
        #expect(buffer.suffix(4).allSatisfy { $0 == sentinel })
    }
}
