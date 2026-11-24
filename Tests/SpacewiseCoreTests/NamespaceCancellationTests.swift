import Dispatch
import Foundation
import Testing

@testable import SpacewiseCore

/// The poll, counted from the start of a build, at which these tests cancel. Large enough to be well inside the
/// grouping work of every tree used here.
private let cancellationPoll = 1024

struct NamespaceCancellationTests {
    @Test func cancellationDuringGroupingDiscardsTopology() {
        var nodes = [ScanNode(id: 0, parent: nil, name: "/", kind: .directory, device: 0, inode: 0)]
        for id in 1...100_000 {
            nodes.append(
                ScanNode(id: id, parent: 0, name: "entry\(id)", kind: .directory, device: 0, inode: UInt64(id)))
        }
        var polls = 0
        let value = LogicalNamespace.build(
            nodes: nodes, rootPaths: [0: "/"], wholeDrive: true,
            isCancelled: {
                polls += 1
                return polls == cancellationPoll
            }, children: { _ in 1..<nodes.count })
        #expect(polls == cancellationPoll)
        #expect(!value.unified)
        #expect(value.hidden.isEmpty)
        #expect(value.members.isEmpty)
        #expect(value.mergedChildren.isEmpty)
    }
}

extension NamespaceCancellationTests {
    struct InProgressCancellation {
        let polls: Int
        let latency: Duration
        let peakRSSBytes: Int
    }

    @Test(arguments: [false, true]) func inProgressCancellationDiscardsTopology(merged: Bool) async {
        _ = await Self.cancelInProgressBuild(count: 100_000, merged: merged)
    }

    /// Builds a namespace over `count` entries and cancels the task at poll `cancellationPoll`, then asserts that
    /// nothing partial survives. The million-entry benchmark runs the same build and reports what it measured.
    static func cancelInProgressBuild(count: Int, merged: Bool) async -> InProgressCancellation {
        var fixture = [
            ScanNode(id: 0, parent: nil, name: "/", kind: .directory, device: 0, inode: 0),
            ScanNode(id: 1, parent: nil, name: "Data", kind: .directory, device: 0, inode: 1),
        ]
        for id in 2..<(count + 2) {
            fixture.append(
                ScanNode(
                    id: id, parent: merged ? id % 2 : 0, name: "entry\(merged ? id / 2 : id)", kind: .directory,
                    device: 0, inode: UInt64(id)))
        }
        let nodes = fixture
        let roots = merged ? [0: "/", 1: "/System/Volumes/Data"] : [0: "/"]
        // The build cancels its own task at the chosen poll. No second thread has to hand off, so nothing here can
        // starve the cooperative pool, and the cancel still arrives through ordinary task cancellation.
        let task = Task.detached { () -> (LogicalNamespace, Int, ContinuousClock.Instant?) in
            var polls = 0
            var cancelledAt: ContinuousClock.Instant?
            let value = LogicalNamespace.build(
                nodes: nodes, rootPaths: roots, wholeDrive: true,
                isCancelled: {
                    polls += 1
                    if polls == cancellationPoll {
                        cancelledAt = .now
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return Task.isCancelled
                },
                children: { parent in
                    parent < 2
                        ? stride(
                            from: merged ? (parent == 0 ? 2 : 3) : 2, to: nodes.count,
                            by: merged ? 2 : (parent == 0 ? 1 : nodes.count)) : stride(from: 0, to: 0, by: 1)
                })
            return (value, polls, cancelledAt)
        }
        let (value, polls, cancelledAt) = await task.value
        let elapsed = cancelledAt.map { $0.duration(to: .now) } ?? .zero
        #expect(cancelledAt != nil, "the build must reach poll \(cancellationPoll) for this to test a mid-build cancel")
        #expect(!value.unified && value.hidden.isEmpty && value.members.isEmpty && value.mergedChildren.isEmpty)
        #expect(polls == cancellationPoll)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return InProgressCancellation(polls: polls, latency: elapsed, peakRSSBytes: usage.ru_maxrss)
    }

    @Test func mergedInterruptionDiscardsPartialTopology() {
        let nodes = (0..<202).map { id in
            ScanNode(
                id: id, parent: id < 2 ? nil : id % 2, name: id < 2 ? "/" : "same", kind: .directory, device: 0,
                inode: UInt64(id))
        }
        let children = { (parent: Int) -> [Int] in parent < 2 ? Array(stride(from: parent + 2, to: 202, by: 2)) : [] }
        let roots = [0: "/", 1: "/System/Volumes/Data"]
        for stop in [250, 650, 850] {
            var polls = 0
            let value = LogicalNamespace.build(
                nodes: nodes, rootPaths: roots, wholeDrive: true,
                isCancelled: {
                    polls += 1
                    return polls >= stop
                }, children: children)
            #expect(!value.unified)
            #expect(value.members.isEmpty && value.hidden.isEmpty && value.mergedChildren.isEmpty)
        }
        let value = LogicalNamespace.build(nodes: nodes, rootPaths: roots, wholeDrive: true, children: children)
        #expect(value.unified)
        #expect(value.members[2]?.count == 200)
        #expect(value.hidden.count == 199)
    }
}

extension NamespaceCancellationTests {
    @Test func deepPairedMergeUsesExplicitStack() {
        let depth = 20_000
        let nodes = (0..<(depth * 2 + 2)).map { id in
            ScanNode(
                id: id, parent: id < 2 ? nil : id - 2, name: id < 2 ? "/" : "folder", kind: .directory, device: 1,
                inode: UInt64(id + 1))
        }
        let value = LogicalNamespace.build(
            nodes: nodes, rootPaths: [0: "/", 1: "/System/Volumes/Data"], wholeDrive: true,
            children: { id in id + 2 < nodes.count ? [id + 2] : [] })
        #expect(value.members.count == depth)
        #expect(value.hidden.count == depth)
        // 20,000 levels: assert once per property, so a failure still names the levels. `mergedChildren` is a computed
        // property that rebuilds its whole dictionary on every read, so it is read once, not once per level.
        let mergedChildren = value.mergedChildren
        var wrongMembers: [Int] = []
        var wrongHidden: [Int] = []
        var wrongChildren: [Int] = []
        var wrongParent: [Int] = []
        for id in stride(from: 2, to: nodes.count, by: 2) {
            if value.members[id] != [id, id + 1] { wrongMembers.append(id) }
            if value.hidden[id + 1] != id { wrongHidden.append(id) }
            if mergedChildren[id] != (id + 2 < nodes.count ? [id + 2] : []) { wrongChildren.append(id) }
            if value.parent(of: id, nodes: nodes) != (id == 2 ? nil : id - 2) { wrongParent.append(id) }
        }
        #expect(wrongMembers.isEmpty, "levels with the wrong members: \(wrongMembers.prefix(5))")
        #expect(wrongHidden.isEmpty, "levels whose twin is not hidden behind it: \(wrongHidden.prefix(5))")
        #expect(wrongChildren.isEmpty, "levels with the wrong merged children: \(wrongChildren.prefix(5))")
        #expect(wrongParent.isEmpty, "levels with the wrong logical parent: \(wrongParent.prefix(5))")
    }
}

extension NamespaceCancellationTests {
    @Test func taskCancellationInsideDeepMerge() async {
        let depth = 20_000
        let nodes = (0..<(depth * 2 + 2)).map { id in
            ScanNode(
                id: id, parent: id < 2 ? nil : id - 2, name: "folder", kind: .directory, device: 1,
                inode: UInt64(id + 1))
        }
        let task = Task.detached { () -> (LogicalNamespace, ContinuousClock.Instant?) in
            var cancelledAt: ContinuousClock.Instant?
            let value = LogicalNamespace.build(
                nodes: nodes, rootPaths: [0: "/", 1: "/System/Volumes/Data"], wholeDrive: true,
                children: { id in
                    // This parent is reached only after 10,000 paired merge frames.
                    if id == 20_000, cancelledAt == nil {
                        cancelledAt = .now
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return id + 2 < nodes.count ? [id + 2] : []
                })
            return (value, cancelledAt)
        }
        let (value, cancelledAt) = await task.value
        #expect(cancelledAt != nil, "the build must reach the deep parent for this to test a mid-build cancel")
        #expect(!value.unified && value.members.isEmpty && value.hidden.isEmpty && value.mergedChildren.isEmpty)
        let rebuilt = LogicalNamespace.build(
            nodes: nodes, rootPaths: [0: "/", 1: "/System/Volumes/Data"], wholeDrive: true,
            children: { id in id + 2 < nodes.count ? [id + 2] : [] })
        #expect(rebuilt.members.count == depth && rebuilt.hidden.count == depth)
        #expect(rebuilt.mergedChildren[depth * 2] == [])
    }
}
