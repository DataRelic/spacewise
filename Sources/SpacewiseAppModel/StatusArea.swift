import Foundation
import SpacewiseCore

/// The one status line above the map. However many conditions hold, the window shows at most one line, chosen in
/// this order (highest first):
///
/// 1. **Scanning**, then **Stopping**: a scan in progress is the only thing happening, and there are no settled
///    results yet for anything else to describe.
/// 2. **Nothing could be scanned**: there are no results, so nothing else applies.
/// 3. **Scan stopped**: the results are incomplete, and their age doesn't change that. The subtitle shows the age.
/// 4. **Some folders couldn't be read**: keep Scan Details, Rescan, and applicable permission recovery visible
///    as the results age. The subtitle shows the age.
/// 5. **Results may be out of date**: prompt for a rescan when otherwise complete results age.
/// 6. **Scan complete**: a brief confirmation right after a scan finishes, then nothing. A complete scan has no
///    persistent line.
public enum StatusArea {
    /// How long the completion confirmation stays before the line goes away.
    public static let confirmationSeconds: TimeInterval = 4

    /// The line to show, or nil for none. `age` is how old settled results are; `confirmsCompletion` is true only
    /// for a moment after a scan finishes.
    public static func make(
        phase: ScanPhase, progress: ScanProgress?, scopeName: String, coverage: LocationCoverage?,
        age: TimeInterval?, confirmsCompletion: Bool
    ) -> Banner? {
        guard
            let outcome = StatusPresentation.outcome(
                phase: phase, progress: progress ?? ScanProgress(),
                scopeName: scopeName, coverage: coverage,
                offersAccessSettings: offersAccessSettings(coverage))
        else { return nil }
        switch outcome.kind {
        case .scanning, .stopping, .nothingScanned, .stopped, .couldNotReadAll, .movingToTrash:
            return outcome
        case .stale, .complete:
            break
        }
        if phase == .settled, let age, let stale = StatusPresentation.freshness(ResultFreshness.evaluate(age: age)) {
            return stale
        }
        if outcome.kind == .complete { return confirmsCompletion ? outcome : nil }
        return outcome
    }

    /// True when the scan was denied folders that macOS doesn't always keep closed: the case where Full Disk Access
    /// may help. Denials in areas macOS protects from every app are expected and don't qualify. Spacewise only offers
    /// the Settings pane; it never requests, changes or checks the permission.
    public static func offersAccessSettings(_ coverage: LocationCoverage?) -> Bool {
        guard let coverage else { return false }
        return ScanDetails.make(coverage).deniedNeedingAttention > 0
    }
}
