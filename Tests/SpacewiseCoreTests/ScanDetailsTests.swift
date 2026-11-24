import Foundation
import Testing

@testable import SpacewiseCore

@Test func expectedOnlyDetailsHaveNoAttentionGroupOrPathsByDefault() {
    var coverage = LocationCoverage(wholeDrive: true)
    coverage.record(path: "/dev", nodeID: nil, operation: .traverse, reason: .policyExcluded)
    coverage.record(
        path: "/System/Volumes/Data/private/var/db/protected", nodeID: nil, operation: .open, reason: .denied)
    coverage.record(path: "/dev/disk1s4", nodeID: nil, operation: .rootVolume, reason: .unmounted)
    let details = ScanDetails.make(coverage)
    #expect(!details.needsAttention)
    #expect(details.groups.map(\.title) == ["Expected limits"])
    let total: UInt64 = details.groups[0].lines.reduce(0) { $0 + $1.count }
    #expect(total == 3)
    #expect(!details.text.contains("/dev") && !details.text.contains("/System"))  // the paths are a further disclosure
    #expect(details.text.contains("Unread areas remain unknown"))
    #expect(details.text.hasSuffix(ScanDetails.sizesNote))  // what sizes mean is said here, once
    #expect(ScanDetails.paths(coverage).contains("/dev"))
}

@Test func mixedDetailsKeepGenuineProblemsSeparateAndCounted() {
    var coverage = LocationCoverage(wholeDrive: true)
    // Expected OS denial.
    coverage.record(path: "/System/protected", nodeID: nil, operation: .traverse, reason: .denied)
    coverage.record(path: "/Users/example/chosen", nodeID: nil, operation: .open, reason: .denied)  // actionable denial
    coverage.record(path: "/Users/example/broken", nodeID: nil, operation: .readdir, reason: .enumeration)
    coverage.record(path: "/dev", nodeID: nil, operation: .traverse, reason: .volumeBoundary)
    let details = ScanDetails.make(coverage)
    #expect(details.needsAttention && details.groups.map(\.title) == ["Needs attention", "Expected limits"])
    let attention = details.groups[0].lines
    let expected = details.groups[1].lines
    #expect(attention.first { $0.title == "Access denied" }?.count == 1)
    #expect(attention.first { $0.title == "Couldn’t be read" }?.count == 1)
    #expect(expected.first { $0.title == "Protected macOS areas" }?.count == 1)
    let attentionTotal: UInt64 = attention.reduce(0) { $0 + $1.count }
    let expectedTotal: UInt64 = expected.reduce(0) { $0 + $1.count }
    #expect(attentionTotal + expectedTotal == details.totalEvents)
    let paths = ScanDetails.paths(coverage)
    #expect(paths.hasPrefix("NEEDS ATTENTION") && paths.contains("EXPECTED LIMITS"))
}

@Test func truncationNeverHidesAnActionableDenial() {
    var coverage = LocationCoverage(limit: 1, wholeDrive: true)
    coverage.record(path: "/System/a", nodeID: nil, operation: .open, reason: .denied)
    coverage.record(path: "/System/b", nodeID: nil, operation: .open, reason: .denied)
    coverage.record(path: "/Users/example/chosen", nodeID: nil, operation: .open, reason: .denied)
    let details = ScanDetails.make(coverage)
    #expect(coverage.truncated && details.truncated)
    #expect(details.groups.first?.title == "Needs attention")
    #expect(details.groups.first?.lines.first?.count == 1)
    #expect(details.groups.last?.lines.first?.count == 2)
    #expect(details.text.contains("Only some locations were kept"))
}

@Test func cleanCoverageHasNoGroups() {
    #expect(ScanDetails.make(LocationCoverage()).groups.isEmpty)
    #expect(ScanDetails.make(LocationCoverage()).text.hasPrefix("Nothing was left unread."))
}
