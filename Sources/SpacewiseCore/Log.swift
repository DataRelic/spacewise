import os

/// Unified logging for the core: one subsystem, one category per area.
///
/// Logs carry counts, durations, fixed enumerations and error codes only, each marked public so a bug report is
/// readable. They never carry a path, a file name or a volume name, not even inside an interpolated error: the scan
/// result keeps those locally, and Scan details is the only place they are shown.
public enum SpacewiseLog {
    /// Matches the bundle identifier's prefix; change the two together.
    public static let subsystem = "local.spacewise"
    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let discovery = Logger(subsystem: subsystem, category: "discovery")

    /// "denied=3 metadata=1": issue counts by reason, from fixed reason names and numbers only.
    static func issueCounts(_ issues: [CoverageIssue: UInt64]) -> String {
        let parts = CoverageIssue.allCases.compactMap { issue in issues[issue].map { "\(issue.rawValue)=\($0)" } }
        return parts.isEmpty ? "none" : parts.joined(separator: " ")
    }

    /// "13x4 1x2": errno values seen in retained coverage records, most frequent first.
    static func errnoCounts(_ records: [CoverageRecord]) -> String {
        var counts: [Int32: UInt64] = [:]
        for record in records { if let code = record.errnoCode { counts[code, default: 0] += record.count } }
        let parts = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key)x\($0.value)" }
        return parts.isEmpty ? "none" : parts.joined(separator: " ")
    }
}
