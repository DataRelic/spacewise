import Foundation
import Testing

@testable import SpacewiseCore

// The million-entry runs of tests whose smaller versions are in the normal suite, plus the memory and timing they
// print. They assert the same counters as the small runs; the numbers are observations, never gates.
//
//     SPACEWISE_BENCH=1 swift test -c release --filter ScaleBenchmarks
//
// For the full index benchmark, one process per cell, see IndexScaleBenchmark.swift.

@Suite(.benchmark, .serialized)
struct ScaleBenchmarks {
    @Test func namespaceAppendWorkAtOneMillionEntries() {
        let count = 1_000_000
        let elapsed = checkNamespaceAppendWorkIsLinear(count: count)
        print("BENCH namespace-append entries=\(count) elapsed=\(elapsed)")
    }

    @Test(arguments: [false, true]) func inProgressCancellationAtOneMillionEntries(merged: Bool) async {
        let count = 1_000_000
        let result = await NamespaceCancellationTests.cancelInProgressBuild(count: count, merged: merged)
        print(
            "BENCH namespace-cancel entries=\(count) merged=\(merged) polls=\(result.polls) latency=\(result.latency) peakRSSBytes=\(result.peakRSSBytes)"
        )
    }

    @Test(arguments: [false, true]) func weightedCategoryTotalsAtScale(deep: Bool) {
        let measurement = measureWeightedCategories(deep: deep, nodes: deep ? 20_000 : 100_000, queries: 10_000)
        print(
            "BENCH weighted-categories deep=\(deep) nodes=\(measurement.nodes) construction=\(measurement.construction) queries=\(measurement.queries) rss=\(measurement.memory.residentBytes ?? 0) peak=\(measurement.memory.peakRSSBytes ?? 0)"
        )
    }
}
