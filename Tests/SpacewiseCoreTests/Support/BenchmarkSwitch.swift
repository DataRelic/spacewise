import Foundation
import Testing

/// Benchmarks measure scale and print numbers; they build million-entry fixtures that take seconds and hundreds of
/// megabytes. They are skipped unless asked for, so a plain `swift test` stays fast and small:
///
///     SPACEWISE_BENCH=1 swift test -c release --filter ScaleBenchmarks
enum BenchmarkSwitch {
    static let isOn = ProcessInfo.processInfo.environment["SPACEWISE_BENCH"] != nil
}

extension Trait where Self == ConditionTrait {
    /// Runs the test only when `SPACEWISE_BENCH` is set.
    static var benchmark: Self { .enabled(if: BenchmarkSwitch.isOn, "set SPACEWISE_BENCH=1 to run benchmarks") }
}
