import Foundation
import SpacewiseAppModel
import Testing

/// A folder that launches the app arrives before the window exists; it is scanned once the window does.
struct LaunchFolderTests {
    private let apps = URL(fileURLWithPath: "/Applications")
    private let library = URL(fileURLWithPath: "/Library")

    @Test func aFolderThatLaunchesTheAppWaitsForTheWindowAndIsScannedOnce() {
        var launch = LaunchFolder()
        #expect(launch.received(apps) == nil)
        #expect(launch.windowBecameReady() == apps)
        #expect(launch.windowBecameReady() == nil)
    }

    @Test func aFolderDroppedOnARunningAppIsScannedAtOnce() {
        var launch = LaunchFolder()
        #expect(launch.windowBecameReady() == nil)
        #expect(launch.received(apps) == apps)
        #expect(launch.received(library) == library)
    }

    @Test func onlyTheLatestFolderIsHeldBecauseAScanHasOneRoot() {
        var launch = LaunchFolder()
        #expect(launch.received(apps) == nil)
        #expect(launch.received(library) == nil)
        #expect(launch.windowBecameReady() == library)
    }

    @Test func aPlainLaunchHasNothingToScan() {
        var launch = LaunchFolder()
        #expect(launch.windowBecameReady() == nil)
    }
}
