import Foundation

/// Cushion-shaded treemap bitmap in the manner of WinDirStat / SequoiaView (van Wijk & van de Wetering).
/// Each tile adds a parabolic ridge to its ancestors' surface, so nesting is visible as shading without borders.
/// Light comes from the top left. `Options` holds the cushion height, scale and ambient defaults.
/// Pure and deterministic: RGBA8, premultiplied (all pixels opaque), rows top to bottom.
public enum TreemapRaster {
    private static let rowsPerCancellationCheck = 16

    public struct Options: Sendable {
        public var dark = false
        public var cushionHeight = 0.36
        public var scaleFactor = 0.91
        /// Light shadows: a high ambient floor keeps cushion edges colourful instead of muddy.
        public var ambient = 0.36
        public var gain = 1.08
        /// Specular highlight on each cushion crest (the "shiny" look), a fixed soft sheen (exponent 16 by repeated
        /// squaring, no pow per pixel).
        public var specular = 0.12
        /// Increase Contrast: a dark one-pixel edge on every tile, so neighbours separate without relying on shading.
        public var tileEdges = false
        public init(dark: Bool = false, tileEdges: Bool = false) {
            self.dark = dark
            self.tileEdges = tileEdges
            if dark {
                ambient = 0.30
                gain = 1.0
                specular = 0.10
            }
        }
    }

    /// `scale` converts layout points to pixels (backing scale). Tiles smaller than a pixel are skipped.
    public static func render(
        model: TreemapModel, layout: TreemapLayout, pixelWidth: Int, pixelHeight: Int,
        scale: Double, options: Options = Options(),
        isCancelled: () -> Bool = { false }
    ) -> [UInt8] {
        let width = max(1, pixelWidth)
        let height = max(1, pixelHeight)
        return [UInt8](unsafeUninitializedCapacity: width * height * 4) { buffer, count in
            render(
                model: model, layout: layout, into: buffer, pixelWidth: width, pixelHeight: height, scale: scale,
                options: options, isCancelled: isCancelled)
            count = width * height * 4
        }
    }

    /// Renders into `pixels`, which must hold `pixelWidth × pixelHeight × 4` bytes. Cancellation may stop tile shading,
    /// but the backdrop always initializes the entire raster, including when called by the array overload.
    public static func render(
        model: TreemapModel, layout: TreemapLayout, into pixels: UnsafeMutableBufferPointer<UInt8>,
        pixelWidth: Int, pixelHeight: Int, scale: Double, options: Options = Options(),
        isCancelled: () -> Bool = { false }
    ) {
        _ = render(
            model: model, layout: layout, into: pixels, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            scale: scale, options: options, isCancelled: isCancelled, cancelBackdrop: false)
    }

    /// Renders directly into the app's disposable image buffer. On false, the buffer may be partially uninitialized
    /// and must be discarded without reading it.
    package static func renderIfNotCancelled(
        model: TreemapModel, layout: TreemapLayout, into pixels: UnsafeMutableBufferPointer<UInt8>,
        pixelWidth: Int, pixelHeight: Int, scale: Double, options: Options = Options(),
        isCancelled: () -> Bool
    ) -> Bool {
        render(
            model: model, layout: layout, into: pixels, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            scale: scale, options: options, isCancelled: isCancelled, cancelBackdrop: true)
    }

    private static func render(
        model: TreemapModel, layout: TreemapLayout, into pixels: UnsafeMutableBufferPointer<UInt8>,
        pixelWidth: Int, pixelHeight: Int, scale: Double, options: Options,
        isCancelled: () -> Bool, cancelBackdrop: Bool
    ) -> Bool {
        let width = max(1, pixelWidth)
        let height = max(1, pixelHeight)
        precondition(
            pixels.count >= width * height * 4,
            "TreemapRaster: buffer of \(pixels.count) bytes is smaller than \(width)x\(height) pixels")
        // Opaque backdrop so any sub-pixel seam reads as the tile palette rather than transparency.
        let backdrop = TreemapPalette.backdrop(dark: options.dark)
        let back = (UInt8(backdrop.r * 255), UInt8(backdrop.g * 255), UInt8(backdrop.b * 255))
        let rowBytes = width * 4
        for row in stride(from: 0, to: height, by: rowsPerCancellationCheck) {
            if cancelBackdrop, isCancelled() { return false }
            let end = min(height, row + rowsPerCancellationCheck)
            for i in stride(from: row * rowBytes, to: end * rowBytes, by: 4) {
                pixels[i] = back.0
                pixels[i + 1] = back.1
                pixels[i + 2] = back.2
                pixels[i + 3] = 255
            }
        }
        guard !model.isEmpty else { return !cancelBackdrop || !isCancelled() }

        let lx = -1.0
        let ly = -1.0
        let lz = 10.0
        let length = (lx * lx + ly * ly + lz * lz).squareRoot()
        let lightX = lx / length
        let lightY = ly / length
        let lightZ = lz / length
        let diffuse = 1 - options.ambient
        // Blinn half vector for a viewer straight above the map.
        let hx0 = lightX
        let hy0 = lightY
        let hz0 = lightZ + 1
        let hLength = (hx0 * hx0 + hy0 * hy0 + hz0 * hz0).squareRoot()
        let halfX = hx0 / hLength
        let halfY = hy0 / hLength
        let halfZ = hz0 / hLength

        func pixelRect(_ rect: CGRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
            (
                max(0, Int((Double(rect.minX) * scale).rounded())),
                max(0, Int((Double(rect.minY) * scale).rounded())),
                min(width, Int((Double(rect.maxX) * scale).rounded())),
                min(height, Int((Double(rect.maxY) * scale).rounded()))
            )
        }
        var surfaces = [(Double, Double, Double, Double)](repeating: (0, 0, 0, 0), count: model.tiles.count)
        for (index, tile) in model.tiles.enumerated() {
            if index & 0x1F == 0, isCancelled() { return false }
            let box = pixelRect(layout.rects[index])
            let w = Double(box.x1 - box.x0)
            let h = Double(box.y1 - box.y0)
            var surface = tile.parent >= 0 ? surfaces[tile.parent] : (0, 0, 0, 0)
            if w >= 1, h >= 1 {
                let ridge = options.cushionHeight * pow(options.scaleFactor, Double(tile.depth))
                let wf = 4 * ridge / w
                let hf = 4 * ridge / h
                surface.2 += wf * Double(box.x1 + box.x0)
                surface.0 -= wf
                surface.3 += hf * Double(box.y1 + box.y0)
                surface.1 -= hf
            }
            surfaces[index] = surface
            guard tile.isLeaf, w >= 1, h >= 1 else { continue }
            let color = TreemapPalette.fill(tile, dark: options.dark)
            let hatch = tile.category == .folderBlock ? 1 : (tile.category == .grouped ? 2 : 0)
            let woven = tile.managed
            let edges = options.tileEdges
            for y in box.y0..<box.y1 {
                if (y - box.y0).isMultiple(of: rowsPerCancellationCheck), isCancelled() { return false }
                let ny = -(2 * surface.1 * (Double(y) + 0.5) + surface.3)
                var offset = (y * width + box.x0) * 4
                for x in box.x0..<box.x1 {
                    let nx = -(2 * surface.0 * (Double(x) + 0.5) + surface.2)
                    let norm = (nx * nx + ny * ny + 1).squareRoot()
                    var cosine = (nx * lightX + ny * lightY + lightZ) / norm
                    if cosine > 1 { cosine = 1 }
                    var shade = max(0, diffuse * cosine) + options.ambient
                    let facing = max(0, (nx * halfX + ny * halfY + halfZ) / norm)
                    let f2 = facing * facing
                    let f4 = f2 * f2
                    let f8 = f4 * f4
                    let shine = options.specular * f8 * f8
                    // Non-colour cues: hatched folder blocks and stippled summed groups.
                    if hatch == 1, ((x + y) / 3) & 1 == 0 {
                        shade *= 0.86
                    } else if hatch == 2, ((x / 2) + (y / 2)) & 1 == 0 {
                        shade *= 0.90
                    }
                    // System-managed tiles carry a woven texture: fine crossed lines, visible without colour.
                    if woven {
                        if (x + y) & 3 == 0 {
                            shade *= 0.88
                        } else if (x - y) & 7 == 0 {
                            shade *= 1.06
                        }
                    }
                    shade *= options.gain
                    if edges, x == box.x0 || y == box.y0 { shade *= 0.4 }
                    pixels[offset] = UInt8(max(0, min(255, (color.r * shade + shine) * 255)))
                    pixels[offset + 1] = UInt8(max(0, min(255, (color.g * shade + shine) * 255)))
                    pixels[offset + 2] = UInt8(max(0, min(255, (color.b * shade + shine) * 255)))
                    offset += 4
                }
            }
        }
        return !cancelBackdrop || !isCancelled()
    }
}

extension TreemapPalette {
    /// The map's backdrop. The raster fills behind its tiles with it (truncated to bytes: 28, 29, 33 dark and
    /// 226, 228, 233 light), and the view draws it behind the image and as the wash that dims tiles during legend focus.
    public static func backdrop(dark: Bool) -> RGB {
        dark ? RGB(r: 0.11, g: 0.115, b: 0.13) : RGB(r: 0.89, g: 0.895, b: 0.915)
    }
}
