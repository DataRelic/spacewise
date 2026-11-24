import Synchronization

/// A test clock that moves forward by `step` every time it is read, so a scan's publication cadence depends only on
/// how often the scanner looks at the time, never on how fast the machine is. `elapsed` reads it without moving it.
final class SteppingClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (left: Instant, right: Instant) -> Bool { left.offset < right.offset }
    }

    let step: Duration
    private let current = Mutex(Duration.zero)

    init(step: Duration) { self.step = step }

    var now: Instant {
        current.withLock { offset in
            offset += step
            return Instant(offset: offset)
        }
    }
    func advance(by duration: Duration) { current.withLock { $0 += duration } }

    var elapsed: Duration { current.withLock { $0 } }
    var minimumResolution: Duration { .nanoseconds(1) }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        preconditionFailure("SteppingClock does not sleep; the scanner only reads the time")
    }
}
