import Foundation
import SpacewiseAppModel
import SpacewiseCore
import Testing

/// One status line at a time, chosen in a fixed order; Full Disk Access is offered only when folders were denied
/// that macOS doesn't always keep closed.
@Suite struct StatusAreaTests {
    private static let fresh: TimeInterval = 60
    private static let stale: TimeInterval = ResultFreshness.staleAfter + 60

    private func progress(_ state: ScanState) -> ScanProgress {
        var progress = ScanProgress()
        progress.state = state
        progress.entries = 12
        progress.elapsedSeconds = 3
        return progress
    }

    /// A denial in a folder the person can do something about.
    private func deniedChosenFolder() -> LocationCoverage {
        var coverage = LocationCoverage(wholeDrive: true)
        coverage.record(path: "/Users/example/chosen", nodeID: nil, operation: .open, reason: .denied)
        return coverage
    }

    /// A denial macOS imposes on every app, which Full Disk Access doesn't change.
    private func deniedProtectedArea() -> LocationCoverage {
        var coverage = LocationCoverage(wholeDrive: true)
        coverage.record(path: "/System/protected", nodeID: nil, operation: .open, reason: .denied, errnoCode: EACCES)
        return coverage
    }

    /// A read failure that has nothing to do with permission.
    private func unreadableFolder() -> LocationCoverage {
        var coverage = LocationCoverage(wholeDrive: true)
        coverage.record(path: "/Users/example/broken", nodeID: nil, operation: .readdir, reason: .enumeration)
        return coverage
    }

    private func status(
        _ state: ScanState, phase: ScanPhase = .settled, coverage: LocationCoverage? = nil,
        age: TimeInterval? = fresh, confirming: Bool = false
    ) -> Banner? {
        StatusArea.make(
            phase: phase, progress: progress(state), scopeName: "Example", coverage: coverage, age: age,
            confirmsCompletion: confirming)
    }

    // MARK: Priority

    @Test func scanningAndStoppingOutrankEverything() {
        #expect(status(.scanning, phase: .scanning, coverage: deniedChosenFolder(), age: Self.stale)?.kind == .scanning)
        #expect(status(.scanning, phase: .stopping, coverage: deniedChosenFolder(), age: Self.stale)?.kind == .stopping)
    }

    @Test func nothingScannedOutranksStaleness() {
        #expect(status(.invalid, age: Self.stale)?.kind == .nothingScanned)
    }

    @Test func aStoppedScanOutranksStaleness() {
        #expect(status(.cancelled, age: Self.stale)?.kind == .stopped)
    }

    @Test(arguments: [ResultFreshness.staleAfter - 1, ResultFreshness.staleAfter, Self.stale])
    func actionableCoverageKeepsRecoveryAcrossTheAgeThreshold(age: TimeInterval) {
        let denied = status(.limited, coverage: deniedChosenFolder(), age: age)
        #expect(denied?.kind == .couldNotReadAll)
        #expect(denied?.actions == [.coverageDetails, .rescan, .privacySettings])
        let unreadable = status(.limited, coverage: unreadableFolder(), age: age)
        #expect(unreadable?.kind == .couldNotReadAll)
        #expect(unreadable?.actions == [.coverageDetails, .rescan])
        #expect(status(.limited, coverage: deniedProtectedArea(), age: Self.stale)?.kind == .stale)
    }

    @Test func aCompleteScanConfirmsBrieflyThenShowsNothing() {
        #expect(status(.completed, confirming: true)?.kind == .complete)
        #expect(status(.completed, confirming: false) == nil)
        #expect(status(.completed, age: Self.stale, confirming: true)?.kind == .stale)
        // Limits that exist by design are not a problem: the scan counts as complete.
        #expect(status(.limited, coverage: deniedProtectedArea(), confirming: false) == nil)
        #expect(status(.limited, coverage: deniedProtectedArea(), confirming: true)?.kind == .complete)
    }

    @Test func theReadyScreenHasNoStatusLine() {
        #expect(status(.scanning, phase: .ready, age: nil, confirming: true) == nil)
    }

    @Test func aLimitedScanSaysSoInOneSentenceWithScanDetails() throws {
        let line = try #require(status(.limited, coverage: unreadableFolder()))
        #expect(line.detail.isEmpty && line.title.hasSuffix("."))
        #expect(line.actions == [.coverageDetails, .rescan])
    }

    // MARK: Full Disk Access

    @Test func privacySettingsAreOfferedOnlyWhenFoldersWereDenied() throws {
        #expect(StatusArea.offersAccessSettings(deniedChosenFolder()))
        #expect(!StatusArea.offersAccessSettings(deniedProtectedArea()))
        #expect(!StatusArea.offersAccessSettings(unreadableFolder()))
        #expect(!StatusArea.offersAccessSettings(LocationCoverage()))
        #expect(!StatusArea.offersAccessSettings(nil))

        let denied = try #require(status(.limited, coverage: deniedChosenFolder()))
        #expect(denied.actions == [.coverageDetails, .rescan, .privacySettings])
        let unreadable = try #require(status(.limited, coverage: unreadableFolder()))
        #expect(!unreadable.actions.contains(.privacySettings))
    }

    @Test func privacySettingsNeverAppearOutsideTheLimitedLine() {
        for state in [ScanState.completed, .cancelled, .invalid] {
            #expect(
                status(state, coverage: deniedChosenFolder(), confirming: true)?.actions.contains(.privacySettings)
                    != true)
        }
        #expect(
            status(.scanning, phase: .scanning, coverage: deniedChosenFolder())?.actions.contains(.privacySettings)
                != true)
    }
}
