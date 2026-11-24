import Foundation

/// A folder the app is asked to scan from outside: dropped on the Dock icon, or opened with Spacewise from Finder or
/// a shell. When that is what launches the app, AppKit delivers the folder before launch has finished, when there is
/// no window to show a scan in. The folder is held until the window exists, then scanned once.
public struct LaunchFolder: Sendable, Equatable {
    private var windowIsReady = false
    private var held: URL?

    public init() {}

    /// A folder arrived. Returns it when it can be scanned now, or nil when it is held for `windowBecameReady()`.
    /// Only the latest folder is held: a scan has one root.
    public mutating func received(_ folder: URL) -> URL? {
        guard windowIsReady else {
            held = folder
            return nil
        }
        return folder
    }

    /// The window exists. Returns the folder that was waiting for it, once.
    public mutating func windowBecameReady() -> URL? {
        windowIsReady = true
        defer { held = nil }
        return held
    }
}
