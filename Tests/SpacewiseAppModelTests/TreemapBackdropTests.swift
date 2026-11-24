import CoreGraphics
import SpacewiseCore
import SpacewiseFixtures
import Testing

/// The view and the raster share one backdrop definition; the raster's bytes must stay what they were.
@Suite struct TreemapBackdropTests {
    @Test func theRasterBackdropIsTheSharedColourInBytes() throws {
        let empty = PresentationFixtures.scenario(.empty).result
        for dark in [false, true] {
            let model = empty.treemap(parent: 0)
            let layout = TreemapLayout.compute(model, in: CGRect(x: 0, y: 0, width: 4, height: 4))
            let pixels = TreemapRaster.render(
                model: model, layout: layout, pixelWidth: 4, pixelHeight: 4, scale: 1,
                options: .init(dark: dark))
            let expected: [UInt8] = dark ? [28, 29, 33, 255] : [226, 228, 233, 255]
            #expect(Array(pixels.prefix(4)) == expected)
            let shared = TreemapPalette.backdrop(dark: dark)
            #expect([UInt8(shared.r * 255), UInt8(shared.g * 255), UInt8(shared.b * 255), 255] == expected)
        }
    }
}
