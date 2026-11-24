import CoreGraphics
import Foundation
import SpacewiseFixtures
import Testing

@testable import SpacewiseCore

// Timings for the storage map's off-main-thread work: squarified layout, cushion raster and the hand-off of the
// pixel buffer to an image. Observations only; nothing here gates on wall time.
//
//     SPACEWISE_BENCH=1 swift test -c release --filter TreemapRenderBenchmark

@Suite(.benchmark, .serialized)
struct TreemapRenderBenchmark {
    private static func median(_ runs: Int, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            let began = ContinuousClock.now
            body()
            samples.append(began.duration(to: .now).totalSeconds * 1000)
        }
        return samples.sorted()[samples.count / 2]
    }

    @Test func layoutAndRasterAtTypicalAndLargeSizes() {
        let model = PresentationFixtures.storageMap(tailFiles: 4000).treemap(parent: 0)
        for (width, height) in [(1228.0, 352.0), (2400.0, 1400.0)] {
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            var layout = TreemapLayout.compute(model, in: bounds)
            let layoutMs = Self.median(15) { layout = TreemapLayout.compute(model, in: bounds) }
            let pixelWidth = Int(width * 2)
            let pixelHeight = Int(height * 2)
            var bytes = 0
            let rasterMs = Self.median(5) {
                bytes =
                    TreemapRaster.render(
                        model: model, layout: layout, pixelWidth: pixelWidth,
                        pixelHeight: pixelHeight, scale: 2
                    ).count
            }
            let pixels = TreemapRaster.render(
                model: model, layout: layout, pixelWidth: pixelWidth,
                pixelHeight: pixelHeight, scale: 2)
            var copied = 0
            let copyMs = Self.median(15) { copied = Data(pixels).count }
            print(
                "BENCH treemap-render tiles=\(model.tiles.count) points=\(Int(width))x\(Int(height)) "
                    + "layoutMs=\(String(format: "%.3f", layoutMs)) rasterMs=\(String(format: "%.2f", rasterMs)) "
                    + "bufferCopyMs=\(String(format: "%.3f", copyMs)) bytes=\(bytes) copied=\(copied)")
        }
    }

    /// One folder of many similar small items: the case where each squarify row grows long.
    @Test(arguments: [1000, 4096]) func squarifyOneWideFolder(count: Int) {
        var seed: UInt64 = 7
        let weights = (0..<count).map { _ -> Double in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(1000 + (seed >> 33) % 50)
        }.sorted(by: >)
        // A typical panel, and a thin strip where rows of many similar items grow long.
        for bounds in [CGRect(x: 0, y: 0, width: 1228, height: 352), CGRect(x: 0, y: 0, width: 4000, height: 3)] {
            var placed = 0
            let ms = Self.median(9) { placed = TreemapLayout.squarify(weights, in: bounds).count }
            print(
                "BENCH treemap-squarify children=\(count) points=\(Int(bounds.width))x\(Int(bounds.height)) "
                    + "ms=\(String(format: "%.3f", ms)) placed=\(placed)")
        }
    }
}
