import Foundation

public enum SizeFormat {
    /// Decimal units (kB-style, 1000-based) with one decimal below 100: "512 bytes", "4.1 KB", "12.4 GB".
    public static func bytes(_ value: UInt64) -> String {
        if value < 1000 { return "\(value) " + Plural.word(value, "byte", "bytes") }
        let units = ["KB", "MB", "GB", "TB", "PB", "EB"]
        var scaled = Double(value) / 1000
        var index = 0
        while index < units.count - 1, roundedForDisplay(scaled) >= 1000 {
            scaled /= 1000
            index += 1
        }
        let shown = roundedForDisplay(scaled)
        // Decimals follow the rounded number, so 99.96 (which rounds to 100) prints like an exact 100.
        return (shown >= 100 ? String(format: "%.0f", shown) : String(format: "%.1f", shown)) + " " + units[index]
    }
    /// One decimal below 100 and a whole number from 100 up, judged after rounding.
    private static func roundedForDisplay(_ scaled: Double) -> Double {
        let tenths = (scaled * 10).rounded() / 10
        return tenths >= 100 ? scaled.rounded() : tenths
    }
    /// Exact byte count for tooltips and the inspector.
    public static func exact(_ value: UInt64) -> String {
        "\(value.formatted()) " + Plural.word(value, "byte", "bytes")
    }
    public static func count(_ value: UInt64) -> String { value.formatted() }
    public static func spoken(_ value: UInt64) -> String {
        let text = bytes(value)
        return text.replacingOccurrences(of: " KB", with: " kilobytes")
            .replacingOccurrences(of: " MB", with: " megabytes")
            .replacingOccurrences(of: " GB", with: " gigabytes").replacingOccurrences(of: " TB", with: " terabytes")
            .replacingOccurrences(of: " PB", with: " petabytes").replacingOccurrences(of: " EB", with: " exabytes")
    }
    public static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1f s", max(0, seconds)) }
        let whole = Int(seconds)
        if whole < 3600 { return "\(whole / 60) min \(whole % 60) s" }
        return "\(whole / 3600) h \((whole % 3600) / 60) min"
    }
    public static func age(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        if value < 60 { return "less than a minute" }
        if value < 3600 {
            let minutes = value / 60
            return "\(minutes) " + Plural.word(minutes, "minute", "minutes")
        }
        if value < 86_400 {
            let hours = value / 3600
            return "\(hours) " + Plural.word(hours, "hour", "hours")
        }
        let days = value / 86_400
        return "\(days) " + Plural.word(days, "day", "days")
    }
}

/// A share of a whole (0...1), as every view shows it: one decimal, and a share under a tenth of a percent says so
/// instead of rounding to zero. Callers add their own "of …" phrase.
public enum ShareFormat {
    private static let smallestShown = 0.001
    /// "12.3%", or "< 0.1%" below a tenth of a percent.
    public static func percent(_ share: Double) -> String {
        share < smallestShown ? "< 0.1%" : String(format: "%.1f%%", share * 100)
    }
    /// The same value for VoiceOver: "12.3 percent", or "less than 0.1 percent".
    public static func spoken(_ share: Double) -> String {
        share < smallestShown ? "less than 0.1 percent" : String(format: "%.1f", share * 100) + " percent"
    }
}

public enum Plural {
    /// `singular` for exactly one, `plural` for every other count, zero included.
    public static func word<Count: BinaryInteger>(_ count: Count, _ singular: String, _ plural: String) -> String {
        count == 1 ? singular : plural
    }
}

extension Duration {
    /// The duration as fractional seconds, for elapsed-time fields and measurements.
    public var totalSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
