import CoreGraphics
import Foundation
import SpacewiseFixtures
import Testing

@testable import SpacewiseCore

// Palette, shading and label-legibility invariants for the brighter, colourful map.

private let fileTypes: [FileCategory] = [
    .video, .audio, .images, .documents, .archives, .diskImages, .code, .applications, .databases, .other,
]

private func distance(_ a: TreemapPalette.RGB, _ b: TreemapPalette.RGB) -> Double {
    ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)).squareRoot()
}
private func chroma(_ c: TreemapPalette.RGB) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }

@Test(arguments: [false, true])
func fileTypeColoursAreVividAndDistinct(dark: Bool) {
    let colours = fileTypes.map { TreemapPalette.color($0, dark: dark) }
    for (category, colour) in zip(fileTypes, colours) {
        #expect(chroma(colour) >= 0.40, "\(category.title) is too grey")
    }
    for i in colours.indices {
        for j in colours.indices where j > i {
            #expect(
                distance(colours[i], colours[j]) >= 0.24,
                "\(fileTypes[i].title) and \(fileTypes[j].title) are too close")
        }
    }
    // Structural groups stay distinguishable from file types too (they also carry a pattern).
    for structural in [FileCategory.folderBlock, .grouped, .managedZone] {
        #expect(chroma(TreemapPalette.color(structural, dark: dark)) >= 0.17)
    }
}

@Test(arguments: [false, true])
func labelInkIsLegibleOnEveryFill(dark: Bool) {
    let sample = TreemapTile(
        nodeID: 1, parent: 0, kind: .file, category: .other, weight: 1, depth: 1, firstChild: 0, childCount: 0,
        partial: false, itemCount: 0, managed: false, tint: nil)
    func tile(_ category: FileCategory, managed: Bool, tint: FileCategory? = nil) -> TreemapTile {
        TreemapTile(
            nodeID: 1, parent: 0, kind: .file, category: category, weight: 1, depth: 1, firstChild: 0, childCount: 0,
            partial: false, itemCount: 0, managed: managed, tint: tint)
    }
    _ = sample
    for category in FileCategory.allCases where category != .managedZone {
        for managed in [false, true] {
            let style = TreemapPalette.label(on: TreemapPalette.fill(tile(category, managed: managed), dark: dark))
            #expect(
                style.contrast >= 4.5, "\(category.title) managed=\(managed) dark=\(dark) contrast \(style.contrast)")
            #expect(style.scrim <= 0.4, "\(category.title) needs a heavy scrim")
        }
    }
}

@Test func managedFillsDifferFromTheirTypeAndStayRelated() {
    let plain = TreemapTile(
        nodeID: 1, parent: 0, kind: .file, category: .video, weight: 1, depth: 1, firstChild: 0, childCount: 0,
        partial: false, itemCount: 0, managed: false, tint: nil)
    let managed = TreemapTile(
        nodeID: 1, parent: 0, kind: .file, category: .video, weight: 1, depth: 1, firstChild: 0, childCount: 0,
        partial: false, itemCount: 0, managed: true, tint: nil)
    #expect(distance(TreemapPalette.fill(plain, dark: false), TreemapPalette.fill(managed, dark: false)) > 0.2)
    #expect(TreemapPalette.fill(managed, dark: false) != TreemapPalette.color(.video))
}

@Test func tintsApplyOnlyToBlocksAndSummedGroups() {
    for model in [
        PresentationFixtures.storageMap(tailFiles: 1500).treemap(parent: 0),
        PresentationFixtures.wholeDrive().logicalTreemap(parent: nil),
    ] {
        for tile in model.tiles {
            if tile.tint != nil { #expect(tile.category == .folderBlock || tile.category == .grouped) }
        }
        // Summed groups name their main type.
        #expect(model.tiles.contains { $0.category == .grouped && $0.tint != nil })
    }
}

private func singleFileRaster(
    category: FileCategory, managed: Bool, options: TreemapRaster.Options = .init()
) -> [UInt8] {
    let root = TreemapTile(
        nodeID: 0, parent: -1, kind: .folder, category: .folderBlock, weight: 1, depth: 0,
        firstChild: 1, childCount: 1, partial: false, itemCount: 1, managed: false, tint: nil)
    let file = TreemapTile(
        nodeID: 1, parent: 0, kind: .file, category: category, weight: 1, depth: 1,
        firstChild: 0, childCount: 0, partial: false, itemCount: 1, managed: managed, tint: nil)
    let model = TreemapModel(scope: 0, provisional: false, tiles: [root, file], rows: [nil, nil], stats: .init())
    let layout = TreemapLayout.compute(model, in: CGRect(x: 0, y: 0, width: 32, height: 32))
    return TreemapRaster.render(
        model: model, layout: layout, pixelWidth: 32, pixelHeight: 32, scale: 1, options: options)
}

@Test func rasterWritesOpaqueCategoryColourAndDefaultHighlights() {
    var flat = TreemapRaster.Options()
    flat.ambient = 1
    flat.gain = 1
    flat.specular = 0
    for category: FileCategory in [.audio, .images] {
        let pixels = singleFileRaster(category: category, managed: false, options: flat)
        let colour = TreemapPalette.color(category, dark: false)
        let rgba = [UInt8(colour.r * 255), UInt8(colour.g * 255), UInt8(colour.b * 255), 255]
        #expect(pixels.count == 32 * 32 * 4)
        #expect(stride(from: 0, to: pixels.count, by: 4).allSatisfy { pixels[$0..<$0 + 4].elementsEqual(rgba) })
    }

    var matte = TreemapRaster.Options()
    matte.specular = 0
    let unlit = singleFileRaster(category: .audio, managed: false, options: matte)
    let shaded = singleFileRaster(category: .audio, managed: false)
    let greenChannels = stride(from: 1, to: shaded.count, by: 4)
    #expect(greenChannels.contains { Int(shaded[$0]) - Int(unlit[$0]) >= 12 })
    #expect(greenChannels.allSatisfy { shaded[$0] >= unlit[$0] })
}

@Test func managedTilesRenderWithAWovenPatternAndOthersDoNot() {
    var flat = TreemapRaster.Options()
    flat.ambient = 1
    flat.gain = 1
    flat.specular = 0
    let personal = singleFileRaster(category: .audio, managed: false, options: flat)
    let managed = singleFileRaster(category: .audio, managed: true, options: flat)
    // With cushion shading and specular turned off, only the weave can change a managed tile's flat fill.
    let darkStripe = (8 * 32 + 8) * 4
    let lightStripe = (9 * 32 + 9) * 4
    let between = (8 * 32 + 9) * 4
    #expect(personal[darkStripe] == personal[lightStripe] && personal[lightStripe] == personal[between])
    #expect(managed[darkStripe] < managed[between])
    #expect(managed[lightStripe] > managed[between])
    #expect([darkStripe, lightStripe, between].allSatisfy { managed[$0 + 3] == 255 })
}

@Test func blocksAndGroupsInRealisticMapsAreMostlyTintedNotGrey() {
    let model = PresentationFixtures.storageMap(tailFiles: 4000).treemap(parent: 0)
    let untinted = model.tiles.dropFirst().filter {
        $0.isLeaf && ($0.category == .grouped || $0.category == .folderBlock) && $0.tint == nil
    }.reduce(UInt64(0)) { $0 + $1.weight }
    let structural = model.tiles.dropFirst().filter {
        $0.isLeaf && ($0.category == .grouped || $0.category == .folderBlock)
    }.reduce(UInt64(0)) { $0 + $1.weight }
    if structural > 0 { #expect(Double(untinted) / Double(structural) < 0.5) }
}

/// Every pair of file-type colours stays clearly apart for typical vision and the three dichromacies (U21). The
/// previous palette's closest pairs were 7.1 typical, 1.1 protan (images and other files), 1.0 deutan (documents and
/// apps) and 4.2 tritan (images and code), in OKLab × 100.
@Test(arguments: [false, true])
func fileTypeColoursStayApartForCommonColourVisionDeficiencies(dark: Bool) throws {
    let colours = fileTypes.map { ($0, TreemapPalette.color($0, dark: dark)) }
    for vision in ColorVision.allCases {
        let closest = try #require(vision.closestPair(colours))
        print(
            "PALETTE dark=\(dark) vision=\(vision) closest=\(closest.a.title)/\(closest.b.title) difference=\(String(format: "%.1f", closest.difference))"
        )
        #expect(closest.difference >= 9, "\(vision): \(closest.a.title) and \(closest.b.title) are too close")
    }
}

@Test func colourVisionSimulationKeepsGreysAndConfusesClassicPairs() {
    let grey = TreemapPalette.RGB(r: 0.5, g: 0.5, b: 0.5)
    for vision in ColorVision.allCases { #expect(vision.difference(grey, grey) == 0) }
    // A saturated red and a green of similar lightness are far apart for typical vision, close for deuteranopia.
    let red = TreemapPalette.RGB(r: 0.80, g: 0.35, b: 0.20)
    let green = TreemapPalette.RGB(r: 0.45, g: 0.52, b: 0.20)
    #expect(ColorVision.typical.difference(red, green) > 3 * ColorVision.deuteranopia.difference(red, green))
}

@Test func increaseContrastDarkensTileEdgesOnly() throws {
    let model = PresentationFixtures.storageMap(tailFiles: 300).treemap(parent: 0)
    let layout = TreemapLayout.compute(model, in: CGRect(x: 0, y: 0, width: 300, height: 200))
    let plain = TreemapRaster.render(model: model, layout: layout, pixelWidth: 300, pixelHeight: 200, scale: 1)
    let edged = TreemapRaster.render(
        model: model, layout: layout, pixelWidth: 300, pixelHeight: 200, scale: 1,
        options: .init(tileEdges: true))
    let leaf = try #require(
        model.tiles.indices.dropFirst().max { a, b in
            layout.rects[a].width * layout.rects[a].height < layout.rects[b].width * layout.rects[b].height
        })
    let rect = layout.rects[leaf]
    func brightness(_ pixels: [UInt8], _ x: Int, _ y: Int) -> Int {
        let i = (y * 300 + x) * 4
        return Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
    }
    let x0 = Int(rect.minX.rounded())
    let y0 = Int(rect.minY.rounded())
    #expect(brightness(edged, x0, y0 + 5) < brightness(plain, x0, y0 + 5))
    #expect(brightness(edged, Int(rect.midX), Int(rect.midY)) == brightness(plain, Int(rect.midX), Int(rect.midY)))
}
