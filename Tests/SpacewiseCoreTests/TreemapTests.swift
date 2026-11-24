import CoreGraphics
import Foundation
import SpacewiseFixtures
import Synchronization
import Testing

@testable import SpacewiseCore

// Storage-map invariants: bounded tiles, exact area accounting, largest-first drawing, layout geometry,
// selection mapping, honest unknown/partial handling, provisional parity and cancellation.

private let bigMap = PresentationFixtures.storageMap(tailFiles: 4000)

private func leaves(_ model: TreemapModel) -> [TreemapTile] { model.tiles.dropFirst().filter(\.isLeaf) }

@Test func fileCategoriesComeFromNamesAndKindsOnly() {
    #expect(FileCategory.category(name: "Movie.MOV", kind: .file) == .video)
    #expect(FileCategory.category(name: "a.tar.gz", kind: .file) == .archives)
    #expect(FileCategory.category(name: "Xcode.app", kind: .package) == .applications)
    #expect(FileCategory.category(name: "Library.photoslibrary", kind: .package) == .images)
    #expect(FileCategory.category(name: ".gitignore", kind: .file) == .other)  // a dotfile is not an extension
    #expect(FileCategory.category(name: "README", kind: .file) == .other)
    #expect(FileCategory.category(name: "disk.sparsebundle", kind: .package) == .diskImages)
    #expect(FileCategory.allCases.count == Set(FileCategory.allCases.map(\.title)).count)
}

@Test func mapIsBoundedRegardlessOfScanSize() {
    let model = bigMap.treemap(parent: 0)
    #expect(bigMap.nodes.count > 6000)
    #expect(model.tiles.count <= TreemapLimits.standard.maxTiles)
    let small = bigMap.treemap(parent: 0, limits: TreemapLimits(maxTiles: 60))
    #expect(small.tiles.count <= 60)
    #expect(small.stats.limited)
    #expect(small.stats.collapsedFolders > 0)  // budget ended before every folder opened: honestly blocks
    let tiny = bigMap.treemap(parent: 0, limits: TreemapLimits(maxTiles: 2))
    #expect(tiny.tiles.count <= 2)
}

@Test func areaAccountingIsExactAtEveryLevel() throws {
    let model = bigMap.treemap(parent: 0)
    #expect(model.rootWeight == bigMap.nodes[0].allocatedBytes)
    for (index, tile) in model.tiles.enumerated() where tile.childCount > 0 {
        let sum = tile.children.reduce(UInt64(0)) { $0 + model.tiles[$1].weight }
        #expect(sum == tile.weight, "children of tile \(index) must sum to the tile")
    }
    for (index, tile) in model.tiles.enumerated() where tile.nodeID >= 0 && index > 0 && tile.kind != .folder {
        #expect(tile.weight == bigMap.nodes[tile.nodeID].allocatedBytes)  // a drawn item stands for exactly its size
    }
    // The legend is a partition of the map: leaf weights add up to the scope.
    let legendTotal = model.legend().reduce(UInt64(0)) { $0 + $1.weight }
    #expect(legendTotal == model.rootWeight)
    // Parent links and contiguity.
    for (index, tile) in model.tiles.enumerated() where index > 0 {
        #expect(tile.parent >= 0 && tile.parent < index)
        #expect(model.tiles[tile.parent].children.contains(index))
        #expect(tile.depth == model.tiles[tile.parent].depth + 1)
    }
}

@Test func largestFilesAreDrawnWhereverTheySit() throws {
    let model = bigMap.treemap(parent: 0)
    // Docker.raw sits at Users/example/Library/Containers: five folders deep, and must have its own tile.
    let docker = try #require(bigMap.nodes.first { $0.name == "Docker.raw" })
    let tile = try #require(model.tileIndex(forNode: docker.id))
    #expect(
        model.tiles[tile].kind == .file && model.tiles[tile].weight == 46_000_000_000 && model.tiles[tile].depth >= 4)
    // Largest-first property: everything not drawn whose parent is drawn is no heavier than the lightest drawn item.
    let minimumDrawn = model.tiles.dropFirst().filter { $0.kind != .aggregate }.map(\.weight).min() ?? 0
    var undrawnHeavier = 0
    for node in bigMap.nodes where node.allocatedBytes > minimumDrawn {
        guard let parent = node.parent, model.tileIndex(forNode: node.id) == nil,
            parent == 0 || model.tileIndex(forNode: parent) != nil
        else { continue }
        undrawnHeavier += 1
    }
    #expect(undrawnHeavier == 0)
}

@Test func unknownDeniedPlaceholderAndLinkAliasesGetNoAreaButAreNeverZeroed() throws {
    let model = bigMap.treemap(parent: 0)
    for name in ["Mail Downloads", "Cloud Notes.pdf", "Shared link.mov", "Link to home"] {
        let node = try #require(bigMap.nodes.first { $0.name == name })
        #expect(model.tileIndex(forNode: node.id) == nil, "\(name) has no allocated size, so no area")
    }
    // The ancestors that contain unreadable content are flagged as lower bounds, not exact.
    let home = try #require(bigMap.nodes.first { $0.name == "example" })
    let homeTile = try #require(model.tileIndex(forNode: home.id))
    #expect(model.tiles[homeTile].partial)
    #expect(model.rows[homeTile]?.node.allocationUnknown == true)
    #expect(model.stats.partialTiles > 0)
    // The hard-linked file counts once: only the owner has a tile and the scope total matches the scan total.
    let shared = bigMap.nodes.filter { $0.name == "Shared.mov" || $0.name == "Shared link.mov" }
    #expect(shared.filter { $0.allocatedBytes > 0 }.count == 1)
    #expect(model.rootWeight == bigMap.progress.allocatedBytes)
}

@Test func aggregatesAreExactAndNeverDoubleCounted() throws {
    let limits = TreemapLimits(maxTiles: 120)
    let model = bigMap.treemap(parent: 0, limits: limits)
    let aggregates = model.tiles.filter { $0.kind == .aggregate }
    #expect(!aggregates.isEmpty)
    #expect(aggregates.allSatisfy { $0.itemCount > 0 && $0.weight > 0 && $0.nodeID == -1 && $0.category == .grouped })
    #expect(model.stats.itemsGrouped == aggregates.reduce(0) { $0 + $1.itemCount })
    // Drawn items plus grouped items never exceed the folders' children, and no node appears twice.
    var seen = Set<Int>()
    for tile in model.tiles.dropFirst() where tile.nodeID >= 0 { #expect(seen.insert(tile.nodeID).inserted) }
    #expect(model.legend().reduce(UInt64(0)) { $0 + $1.weight } == model.rootWeight)
}

@Test func scopeCanBeAnyFolderAndTheVirtualRoot() throws {
    let library = try #require(
        bigMap.nodes.first { $0.name == "Library" && $0.parent != nil && bigMap.nodes[$0.parent!].name == "example" })
    let zoomed = bigMap.treemap(parent: library.id)
    #expect(zoomed.scope == library.id && zoomed.rootWeight == library.allocatedBytes)
    #expect(zoomed.tiles.dropFirst().allSatisfy { $0.nodeID != library.id })
    let top = bigMap.treemap(parent: nil)  // virtual root over the scan roots
    #expect(top.rootWeight == bigMap.nodes[0].allocatedBytes && top.tiles[0].nodeID == -1)
    let empty = PresentationFixtures.scenario(.empty).result.treemap(parent: 0)
    #expect(empty.isEmpty && empty.rootWeight == 0 && empty.legend().isEmpty)
    #expect(bigMap.treemap(parent: 999_999_999).isEmpty)
}

@Test func squarifiedLayoutTilesParentsExactlyAndProportionally() {
    let model = bigMap.treemap(parent: 0)
    let bounds = CGRect(x: 10, y: 20, width: 1000, height: 640)
    let layout = TreemapLayout.compute(model, in: bounds)
    #expect(layout.rects.count == model.tiles.count && layout.rects[0] == bounds)
    for (index, tile) in model.tiles.enumerated() where tile.childCount > 0 {
        let parent = layout.rects[index]
        var area = 0.0
        for child in tile.children {
            let rect = layout.rects[child]
            #expect(
                rect.minX >= parent.minX - 1e-6 && rect.maxX <= parent.maxX + 1e-6 && rect.minY >= parent.minY - 1e-6
                    && rect.maxY <= parent.maxY + 1e-6)
            area += Double(rect.width * rect.height)
            // Area is proportional to weight within the parent.
            let expected =
                Double(model.tiles[child].weight) / Double(tile.weight) * Double(parent.width * parent.height)
            #expect(abs(Double(rect.width * rect.height) - expected) <= max(1e-6, expected * 1e-6))
        }
        #expect(abs(area - Double(parent.width * parent.height)) <= Double(parent.width * parent.height) * 1e-9 + 1e-9)
    }
    // Siblings never overlap.
    for tile in model.tiles where tile.childCount > 1 {
        let kids = tile.children.map { layout.rects[$0] }
        for i in kids.indices {
            for j in kids.indices where j > i {
                #expect(kids[i].intersection(kids[j]).width * kids[i].intersection(kids[j]).height < 1e-6)
            }
        }
    }
}

@Test func squarifyKeepsTilesCompactAndHandlesDegenerateInput() {
    let weights = (0..<40).map { Double(40 - $0) * Double(40 - $0) }
    let rects = TreemapLayout.squarify(weights, in: CGRect(x: 0, y: 0, width: 800, height: 500))
    let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
    #expect(worst < 6)  // "squarified": no extreme slivers for ordinary distributions
    #expect(TreemapLayout.squarify([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
    #expect(TreemapLayout.squarify([5, 3], in: .zero).allSatisfy { $0.width == 0 && $0.height == 0 })
    let withZero = TreemapLayout.squarify([4, 0, 0], in: CGRect(x: 0, y: 0, width: 10, height: 10))
    #expect(withZero[0].width * withZero[0].height == 100 && withZero[1].width * withZero[1].height == 0)
    let single = TreemapLayout.squarify([7], in: CGRect(x: 0, y: 0, width: 33, height: 11))
    #expect(single[0] == CGRect(x: 0, y: 0, width: 33, height: 11))
}

@Test func hitTestingFindsTheDeepestTileAndNeighborsMoveInTheRequestedDirection() throws {
    let model = bigMap.treemap(parent: 0)
    let layout = TreemapLayout.compute(model, in: CGRect(x: 0, y: 0, width: 900, height: 600))
    for index in model.tiles.indices where model.tiles[index].isLeaf && index > 0 {
        let rect = layout.rects[index]
        guard rect.width >= 2, rect.height >= 2 else { continue }
        #expect(layout.hit(CGPoint(x: rect.midX, y: rect.midY), in: model) == index)
    }
    #expect(layout.hit(CGPoint(x: -5, y: 10), in: model) == nil)
    #expect(layout.hit(CGPoint(x: 900, y: 600), in: model) == nil)  // half-open: the far edge is outside
    let start = try #require(
        model.tiles.indices.dropFirst().first { model.tiles[$0].isLeaf && layout.rects[$0].width > 20 })
    for direction in [TreemapLayout.Direction.left, .right, .up, .down] {
        guard let moved = layout.neighbor(of: start, direction, in: model) else { continue }
        let a = layout.rects[start]
        let b = layout.rects[moved]
        switch direction {
        case .right: #expect(b.minX >= a.maxX - 0.5)
        case .left: #expect(b.maxX <= a.minX + 0.5)
        case .down: #expect(b.minY >= a.maxY - 0.5)
        case .up: #expect(b.maxY <= a.minY + 0.5)
        }
        #expect(moved != start && model.tiles[moved].isLeaf)
    }
}

@Test func selectionMapsToDrawnTilesAndToTheListRow() throws {
    let limits = TreemapLimits(maxTiles: 80)
    let model = bigMap.treemap(parent: 0, limits: limits)
    let parentOf: (Int) -> Int? = { bigMap.nodes[$0].parent }
    // A drawn node maps to itself.
    let drawn = try #require(model.tiles.indices.dropFirst().first { model.tiles[$0].kind == .file })
    #expect(model.nearestTile(forNode: model.tiles[drawn].nodeID, parentOf: parentOf) == drawn)
    // A node inside an unexpanded folder maps to that folder's block (the nearest drawn ancestor).
    let block = try #require(model.tiles.indices.dropFirst().first { model.tiles[$0].kind == .folderBlock })
    let inside = try #require(bigMap.nodes.first { $0.parent == model.tiles[block].nodeID })
    #expect(model.nearestTile(forNode: inside.id, parentOf: parentOf) == block)
    // A node that is not drawn inside an expanded folder maps to that folder's aggregate.
    var found = false
    for (index, tile) in model.tiles.enumerated() where tile.kind == .aggregate && model.tiles[tile.parent].nodeID >= 0
    {
        let folder = model.tiles[tile.parent].nodeID
        if let hidden = bigMap.nodes.first(where: { $0.parent == folder && model.tileIndex(forNode: $0.id) == nil }) {
            #expect(model.nearestTile(forNode: hidden.id, parentOf: parentOf) == index)
            found = true
            break
        }
    }
    #expect(found)
    // The list row for any tile is the ancestor directly under the scope.
    let deep = try #require(model.tiles.indices.dropFirst().max { model.tiles[$0].depth < model.tiles[$1].depth })
    let rowNode = try #require(model.scopeLevelNode(of: deep))
    #expect(bigMap.nodes[rowNode].parent == 0)
    #expect(model.scopeLevelNode(of: 0) == nil)
}

@Test func rasterIsDeterministicOpaqueAndCushionShaded() throws {
    let model = PresentationFixtures.scenario(.complete).result.treemap(parent: 0)
    let layout = TreemapLayout.compute(model, in: CGRect(x: 0, y: 0, width: 400, height: 260))
    let a = TreemapRaster.render(model: model, layout: layout, pixelWidth: 800, pixelHeight: 520, scale: 2)
    let b = TreemapRaster.render(model: model, layout: layout, pixelWidth: 800, pixelHeight: 520, scale: 2)
    #expect(a.count == 800 * 520 * 4 && a == b)
    #expect(stride(from: 3, to: a.count, by: 4).allSatisfy { a[$0] == 255 })
    // The biggest leaf is brighter at its centre than at its edge (a cushion, not flat fill).
    let big = try #require(
        model.tiles.indices.dropFirst().filter { model.tiles[$0].isLeaf }.max {
            layout.rects[$0].width * layout.rects[$0].height < layout.rects[$1].width * layout.rects[$1].height
        })
    let rect = layout.rects[big]
    func luminance(_ x: Int, _ y: Int) -> Int {
        let i = (y * 800 + x) * 4
        return Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2])
    }
    let centre = luminance(Int(rect.midX * 2), Int(rect.midY * 2))
    let edge = luminance(Int(rect.minX * 2) + 1, Int(rect.midY * 2))
    #expect(centre > edge)
    // Dark rendering differs and tiles keep their category hue: a video tile is red-dominant.
    let dark = TreemapRaster.render(
        model: model, layout: layout, pixelWidth: 800, pixelHeight: 520, scale: 2, options: .init(dark: true))
    #expect(dark != a)
    // An empty model renders only the backdrop.
    let empty = PresentationFixtures.scenario(.empty).result.treemap(parent: 0)
    let blank = TreemapRaster.render(
        model: empty, layout: TreemapLayout.compute(empty, in: CGRect(x: 0, y: 0, width: 10, height: 10)),
        pixelWidth: 10, pixelHeight: 10, scale: 1)
    #expect(blank.count == 400 && Set(stride(from: 0, to: 400, by: 4).map { blank[$0] }).count == 1)
}

@Test func rasterColorsFollowTheCategoryPalette() throws {
    let model = bigMap.treemap(parent: 0)
    let layout = TreemapLayout.compute(model, in: CGRect(x: 0, y: 0, width: 900, height: 600))
    let pixels = TreemapRaster.render(model: model, layout: layout, pixelWidth: 900, pixelHeight: 600, scale: 1)
    func centerColor(of index: Int) -> (Int, Int, Int) {
        let rect = layout.rects[index]
        let i = (Int(rect.midY) * 900 + Int(rect.midX)) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }
    let video = try #require(
        model.tiles.indices.dropFirst().first {
            model.tiles[$0].category == .video && layout.rects[$0].width > 8 && layout.rects[$0].height > 8
        })
    let (r, g, b) = centerColor(of: video)
    #expect(r > g && r > b)
    let images = try #require(
        model.tiles.indices.dropFirst().first {
            model.tiles[$0].category == .images && model.tiles[$0].isLeaf && layout.rects[$0].width > 8
                && layout.rects[$0].height > 8
        })
    let (ir, ig, ib) = centerColor(of: images)
    #expect(ig > ir && ig > ib)
}

@Test func cancelledBuildReturnsAValidBoundedModelQuickly() {
    var calls = 0
    let model = TreemapBuilder.build(
        source: SettledTreemapSource(result: bigMap), scope: 0, provisional: false,
        isCancelled: {
            calls += 1
            return true
        })
    // The build polls for cancellation every 256 expansion steps, so a build that is cancelled from the start must
    // have asked at least once and drawn fewer than 256 items, far fewer than the uncancelled map holds.
    #expect(calls > 0, "the build never consulted the cancellation hook")
    #expect(model.stats.limited, "a cancelled build must say it is incomplete")
    #expect(model.stats.itemsDrawn <= 0x100, "drew \(model.stats.itemsDrawn) items after cancellation")
    #expect(model.tiles.count < bigMap.treemap(parent: 0).tiles.count / 4)
    #expect(model.tiles.count <= TreemapLimits.standard.maxTiles && model.rootWeight == bigMap.nodes[0].allocatedBytes)
    for tile in model.tiles where tile.childCount > 0 {
        #expect(tile.children.reduce(UInt64(0)) { $0 + model.tiles[$1].weight } == tile.weight)
    }
}

@Test func provisionalMapUsesIncrementalTotalsAndBoundsItsCost() throws {
    // Build the progressive index exactly as the scanner does, with a folder far wider than the cost budget.
    var nodes = [ScanNode(id: 0, parent: nil, name: "Root", kind: .directory, device: 1, inode: 1)]
    var index = ProgressiveIndex()
    index.append(nodes[0])
    func add(_ parent: Int, _ name: String, _ kind: NodeKind, bytes: UInt64 = 0) -> Int {
        let node = ScanNode(
            id: nodes.count, parent: parent, name: name, kind: kind, logicalBytes: bytes, allocatedBytes: bytes,
            device: 1, inode: UInt64(nodes.count + 1))
        nodes.append(node)
        index.append(node)
        index.attribute(logical: bytes, allocated: bytes, to: parent, nodes: nodes)
        return node.id
    }
    // The scanner enumerates one directory at a time, so each folder's children are contiguous.
    let wide = add(0, "wide", .directory)
    let narrow = add(0, "narrow", .directory)
    for i in 0..<5000 { _ = add(wide, "f\(i).bin", .file, bytes: UInt64(4096 * (i + 1))) }
    let video = add(narrow, "clip.mov", .file, bytes: 900_000_000)
    var progress = ScanProgress()
    progress.state = .scanning
    var coverage = LocationCoverage()
    coverage.enumeration[0] = .partial
    coverage.enumeration[wide] = .partial
    coverage.enumeration[narrow] = .partial
    let source = ProvisionalTreemapSource(
        index: index, nodes: nodes, urls: [URL(fileURLWithPath: "/Synthetic")], coverage: coverage, progress: progress)
    let full = TreemapBuilder.build(source: source, scope: 0, provisional: true, isCancelled: { false })
    #expect(full.provisional && full.rootWeight == index.totals[0]?.allocated)
    #expect(full.tileIndex(forNode: video) != nil)
    #expect(full.tiles.count <= TreemapLimits.standard.maxTiles && full.stats.partialTiles > 0)
    // Every provisional tile is a lower bound while the scan runs.
    #expect(full.tiles.dropFirst().filter { $0.kind != .aggregate && $0.kind != .file }.allSatisfy { $0.partial })
    // Heaviest-first per folder and the exact heaviest child is drawn.
    let firstWide = try #require(full.tileIndex(forNode: wide))
    let heaviest = try #require(
        full.tiles[firstWide].children.map { full.tiles[$0] }.filter { $0.kind == .file }.map(\.weight).max())
    #expect(heaviest == UInt64(4096 * 5000))
    // A tight cost budget refuses to expand the wide folder (it stays one honest block) but never stalls.
    let limited = TreemapBuilder.build(
        source: source, scope: 0, provisional: true, limits: TreemapLimits(maxCost: 100), isCancelled: { false })
    let block = try #require(limited.tileIndex(forNode: wide))
    #expect(limited.tiles[block].kind == .folderBlock && limited.stats.limited)
    #expect(limited.tiles[block].weight == index.totals[wide]?.allocated)
}

@Test func scannerAttachesABoundedMapOnlyWhenRequested() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    for d in 0..<30 {
        let folder = fixture.root.appending(path: "dir-\(d)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for i in 0..<20 {
            try Data(repeating: 7, count: 4096 * (1 + (d + i) % 9)).write(to: folder.appending(path: "file-\(i).bin"))
        }
    }
    let wanted = Mutex<[ScopeSnapshot]>([])
    let unwanted = Mutex<[ScopeSnapshot]>([])
    let result = await Scanner.scan(
        plan: ScanPlan(folder: fixture.root),
        scopeRequest: { ScopeRequest(parent: 0, generation: 1, wantsTreemap: true) },
        scopeUpdate: { snapshot in wanted.withLock { $0.append(snapshot) } }
    ) { _ in }
    _ = await Scanner.scan(
        plan: ScanPlan(folder: fixture.root), scopeRequest: { ScopeRequest(parent: 0) },
        scopeUpdate: { snapshot in unwanted.withLock { $0.append(snapshot) } }
    ) { _ in }
    #expect(unwanted.withLock { $0.allSatisfy { $0.treemap == nil } })
    let snapshots = wanted.withLock { $0 }
    let withMap = snapshots.filter { $0.treemap != nil }
    try #require(withMap.isEmpty == false)
    // The settled map comes from the result.
    #expect(snapshots.last?.provisional == false && snapshots.last?.treemap == nil)
    // The settled map from the result accounts for every allocated byte exactly once.
    let settled = result.treemap(parent: 0)
    #expect(settled.rootWeight == result.progress.allocatedBytes && settled.rootWeight > 0)
    #expect(settled.tiles.filter { $0.kind == .file }.count == 600)
    for snapshot in withMap {
        #expect(snapshot.treemap?.tiles.count ?? 0 <= TreemapLimits.standard.maxTiles && snapshot.treemap?.scope == 0)
    }
}

@Test func disclosureCopyIsHonestAboutWhatTheMapShows() {
    let model = bigMap.treemap(parent: 0, limits: TreemapLimits(maxTiles: 120))
    let text = TreemapPresentation.disclosure(model)
    #expect(
        text.contains("individual tiles") && text.contains("added together") && text.contains("allocated size on disk"))
    #expect(text.contains("Only measured allocation takes up area") && text.contains("direct entries"))
    #expect(text.contains("File Types accounts for all allocated space drawn on the map"))
    for forbidden in ["freed", "reclaim", "safe to delete", "Reserved", "System Data"] {
        #expect(!text.contains(forbidden))
    }
    #expect(TreemapPresentation.disclosure(bigMap.treemap(parent: 0)).contains("folders"))
    let live = TreemapPresentation.disclosure(
        TreemapBuilder.build(
            source: SettledTreemapSource(result: bigMap), scope: 0, provisional: true, isCancelled: { false }))
    #expect(live.contains("still counting") && live.contains("found so far"))
}

@Test func preflightRefusesWideFolderBeforeSelection() {
    final class Visits { var children = 0 }
    struct Source: TreemapSource {
        let visits: Visits
        let base: SettledTreemapSource
        var rootWeight: UInt64 { base.rootWeight }
        func selectionCost(of parent: Int?) -> Int { parent == nil ? 0 : Int.max }
        func largestChildren(of parent: Int?, limit: Int) -> (items: [(id: Int, weight: UInt64)], total: Int, cost: Int)
        {
            if parent != nil { visits.children += 1 }
            return base.largestChildren(of: parent, limit: limit)
        }
        func weight(of id: Int) -> UInt64 { base.weight(of: id) }
        func row(for id: Int) -> ScopeRow? { base.row(for: id) }
    }
    let visits = Visits()
    let source = Source(visits: visits, base: SettledTreemapSource(result: bigMap))
    let map = TreemapBuilder.build(source: source, scope: nil, provisional: true, limits: TreemapLimits(maxCost: 1))
    #expect(visits.children == 0)
    #expect(!map.isEmpty)
    #expect(map.rootWeight == source.rootWeight)
    #expect(map.stats.collapsedFolders > 0)
}
