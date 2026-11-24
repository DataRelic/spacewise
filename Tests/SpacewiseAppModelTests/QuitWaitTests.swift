import SpacewiseAppModel
import Testing

/// Quitting during a scan answers AppKit exactly once: when the stopped scan settles, or when the deadline passes.
struct QuitWaitTests {
    @Test func settlingInTimeQuitsAndTheDeadlineThenDoesNothing() {
        var wait = QuitWait()
        #expect(wait.scanSettled() == .quit)
        #expect(wait.deadlinePassed() == nil)
        #expect(wait.replied)
    }

    @Test func aDeadlineFirstQuitsAfterTimeoutAndALateSettleDoesNothing() {
        var wait = QuitWait()
        #expect(wait.deadlinePassed() == .quitAfterTimeout)
        #expect(wait.scanSettled() == nil)
        #expect(wait.deadlinePassed() == nil)
    }

    @Test func nothingIsRepliedBeforeEither() {
        #expect(!QuitWait().replied)
    }

    @Test func theLimitIsAFewSeconds() {
        #expect(QuitWait.limitSeconds >= 2 && QuitWait.limitSeconds <= 10)
    }
}
