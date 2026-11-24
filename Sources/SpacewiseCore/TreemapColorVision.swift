import Foundation

/// Colour-vision simulation for checking the map palette. Dichromacy is simulated with the Machado, Oliveira and
/// Fernandes (2009) matrices at full severity, applied in linear sRGB; differences are Euclidean distances in OKLab,
/// scaled by 100 so that about 2 is a just-noticeable difference and 10 is clearly distinct at a glance.
public enum ColorVision: CaseIterable, Sendable {
    case typical, protanopia, deuteranopia, tritanopia

    private var matrix: [[Double]]? {
        switch self {
        case .typical: nil
        case .protanopia:
            [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]]
        case .deuteranopia:
            [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]]
        case .tritanopia:
            [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]]
        }
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// The colour as this vision sees it, in linear sRGB.
    func simulateLinear(_ color: TreemapPalette.RGB) -> (Double, Double, Double) {
        let input = [Self.linear(color.r), Self.linear(color.g), Self.linear(color.b)]
        guard let matrix else { return (input[0], input[1], input[2]) }
        func row(_ index: Int) -> Double {
            min(1, max(0, matrix[index][0] * input[0] + matrix[index][1] * input[1] + matrix[index][2] * input[2]))
        }
        return (row(0), row(1), row(2))
    }

    private static func oklab(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let l = cbrt(0.4122214708 * rgb.0 + 0.5363325363 * rgb.1 + 0.0514459929 * rgb.2)
        let m = cbrt(0.2119034982 * rgb.0 + 0.6806995451 * rgb.1 + 0.1073969566 * rgb.2)
        let s = cbrt(0.0883024619 * rgb.0 + 0.2817188376 * rgb.1 + 0.6299787005 * rgb.2)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    /// Perceptual difference between two colours as this vision sees them (OKLab distance × 100).
    public func difference(_ a: TreemapPalette.RGB, _ b: TreemapPalette.RGB) -> Double {
        let x = Self.oklab(simulateLinear(a))
        let y = Self.oklab(simulateLinear(b))
        let dl = x.0 - y.0
        let da = x.1 - y.1
        let db = x.2 - y.2
        return 100 * (dl * dl + da * da + db * db).squareRoot()
    }

    /// The closest pair of colours in a set as this vision sees them.
    public func closestPair<Key>(_ colors: [(Key, TreemapPalette.RGB)]) -> (a: Key, b: Key, difference: Double)? {
        var best: (a: Key, b: Key, difference: Double)?
        for i in colors.indices {
            for j in colors.indices where j > i {
                let value = difference(colors[i].1, colors[j].1)
                if best == nil || value < best!.difference { best = (colors[i].0, colors[j].0, value) }
            }
        }
        return best
    }
}
