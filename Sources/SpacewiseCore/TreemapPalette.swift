import Foundation

/// Deterministic base colours (sRGB 0...1) per category. AppKit and the raster share this table so the file-type
/// list, the cushion pixels and the hover highlight cannot disagree. Ten saturated hues for file types, separated in
/// lightness as well as hue so every pair stays apart for protan, deutan and tritan vision too (`ColorVision`);
/// "Other files" is a warm peach rather than a grey so a map of mostly unrecognised files still reads as colour.
public enum TreemapPalette {
    public struct RGB: Sendable, Equatable { public let r: Double, g: Double, b: Double }
    public static func color(_ category: FileCategory, dark: Bool = false) -> RGB {
        let base: (Double, Double, Double)
        switch category {
        case .video: base = (0.95, 0.20, 0.27)
        case .audio: base = (0.83, 0.29, 0.73)
        case .images: base = (0.07, 0.56, 0.41)
        case .documents: base = (0.34, 0.58, 1.00)
        case .archives: base = (0.94, 0.53, 0.00)
        case .diskImages: base = (1.00, 0.99, 0.42)
        case .code: base = (0.00, 0.78, 0.87)
        case .applications: base = (0.49, 0.27, 0.98)
        case .databases: base = (0.86, 0.85, 0.00)
        case .other: base = (1.00, 0.67, 0.55)
        case .folderBlock: base = (0.36, 0.44, 0.80)
        case .grouped: base = (0.82, 0.76, 0.96)
        case .managedZone: base = (0.30, 0.50, 0.93)
        }
        let scale = dark ? 0.90 : 1.0
        return RGB(r: base.0 * scale, g: base.1 * scale, b: base.2 * scale)
    }
    public static func mix(_ a: RGB, _ b: RGB, _ amount: Double) -> RGB {
        RGB(
            r: a.r * (1 - amount) + b.r * amount,
            g: a.g * (1 - amount) + b.g * amount,
            b: a.b * (1 - amount) + b.b * amount)
    }
    /// What a tile is painted with. Blocks and summed groups borrow the main file type of their largest items (an
    /// estimate, shown with a pattern); system-managed tiles are pulled toward steel blue so the protected region reads
    /// as one group while a system dylib stays readable as code. A pattern carries the same signals without colour.
    public static func fill(_ tile: TreemapTile, dark: Bool) -> RGB {
        var base = color(tile.category, dark: dark)
        if let tint = tile.tint {
            switch tile.category {
            case .folderBlock: base = mix(color(tint, dark: dark), base, 0.28)
            case .grouped: base = mix(color(tint, dark: dark), base, 0.45)
            default: break
            }
        }
        return tile.managed ? mix(base, color(.managedZone, dark: dark), 0.62) : base
    }
    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    /// WCAG relative luminance of a colour as painted by the raster at mid shading.
    public static func luminance(_ color: RGB, shade: Double = 1) -> Double {
        0.2126 * linear(min(1, color.r * shade))
            + 0.7152 * linear(min(1, color.g * shade))
            + 0.0722 * linear(min(1, color.b * shade))
    }
    /// Label treatment for a tile: the ink with the higher contrast, plus the lightest translucent scrim behind the text
    /// that lifts the contrast to at least 4.5:1 (WCAG AA for normal text) wherever the bare fill falls short. The scrim
    /// is black under white ink and white under dark ink. `contrast` is the guaranteed ratio at mid shading.
    public struct LabelStyle: Sendable, Equatable {
        public let darkInk: Bool
        public let scrim: Double
        public let contrast: Double
    }
    public static func label(on color: RGB) -> LabelStyle {
        let l = luminance(color, shade: 0.78)  // labels sit near tile edges, where the cushion is darker
        let darkInkLuminance = 0.007  // linear luminance of the dark ink (an 8 percent gray)
        func style(dark: Bool, step: Int) -> LabelStyle {
            let alpha = Double(step) * 0.05
            let background = dark ? l * (1 - alpha) + alpha : l * (1 - alpha)
            let contrast = dark ? (background + 0.05) / (darkInkLuminance + 0.05) : 1.05 / (background + 0.05)
            return LabelStyle(darkInk: dark, scrim: alpha, contrast: contrast)
        }
        /// The lightest scrim (steps of 5 percent) that reaches 4.5:1, or the strongest, 60 percent, when none does.
        func best(dark: Bool) -> LabelStyle {
            for step in 0..<12 {
                let candidate = style(dark: dark, step: step)
                if candidate.contrast >= 4.5 { return candidate }
            }
            return style(dark: dark, step: 12)
        }
        let white = best(dark: false)
        let dark = best(dark: true)
        return dark.scrim < white.scrim || (dark.scrim == white.scrim && dark.contrast > white.contrast) ? dark : white
    }
}
