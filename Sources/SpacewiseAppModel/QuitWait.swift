/// Quitting during a scan: once the person agrees, the app stops the scan and waits for it to settle before it lets
/// AppKit quit. The wait is bounded, so a scanner stuck in a slow system call cannot keep the app open: whichever
/// comes first, the scan settling or the deadline, answers AppKit, and only once.
public struct QuitWait: Sendable, Equatable {
    /// How long the app waits for a stopped scan to settle before it quits anyway.
    public static let limitSeconds: Double = 4

    public enum Reply: Sendable, Equatable {
        /// The scan settled in time.
        case quit
        /// The deadline passed first; the app quits without waiting further.
        case quitAfterTimeout
    }

    public private(set) var replied = false

    public init() {}

    /// The stopped scan settled. Returns the reply to send, or nil when one was already sent.
    public mutating func scanSettled() -> Reply? {
        guard !replied else { return nil }
        replied = true
        return .quit
    }

    /// The deadline passed. Returns the reply to send, or nil when one was already sent.
    public mutating func deadlinePassed() -> Reply? {
        guard !replied else { return nil }
        replied = true
        return .quitAfterTimeout
    }
}
