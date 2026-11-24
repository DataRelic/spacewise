import Foundation
import Testing

@testable import SpacewiseCore

// C: every map build draws selection, row synthesis and sampling from one ledger (TreemapLimits.maxCost). The tests
// count reads at the base source (below any logical reduction) so an omitted cost fails them.

struct TreemapBudgetTests {
    /// One source under test and the scope to map. `reads` is the live count of base reads.
    struct Subject {
        let name: String
        let scope: Int?
        let counter: WorkCounter
        let build: (TreemapLimits) -> TreemapModel
        let selectionCost: Int
        let weight: UInt64
    }

    private func settledResult(_ tree: Tree, roots: [URL]) -> ScanResult {
        var progress = ScanProgress()
        progress.state = .completed
        return ScanResult(
            id: UUID(), started: Date(), ended: Date(), roots: roots, nodes: tree.settledNodes, progress: progress,
            coverage: wholeDrive, volumes: [])
    }

    /// Broad unified drive: wide top level, wide merged folder, wide managed group.
    private func driveTree() -> (tree: Tree, merged: Int, urls: [URL]) {
        var tree = Tree()
        let system = tree.root("/")
        let data = tree.root("/System/Volumes/Data")
        // Top level: 1,500 unique entries on the Data side, a few System-managed folders.
        let sysFolder = tree.add(system, "System")
        let usr = tree.add(system, "usr")
        let dataSys = tree.add(data, "System")
        for n in 0..<1500 { tree.add(data, "entry\(n).bin", .file, bytes: UInt64(4096 * (1 + n % 7))) }
        // The merged folder: 300 merged subfolders, each with a file on each volume.
        var subs: [(Int, Int)] = []
        for n in 0..<300 { subs.append((tree.add(sysFolder, "sub\(n)"), 0)) }
        for n in 0..<300 { subs[n].1 = tree.add(dataSys, "sub\(n)") }
        for (a, b) in subs {
            tree.add(a, "a.mov", .file, bytes: UInt64(65536 * (1 + a % 5)))
            tree.add(b, "b.txt", .file, bytes: UInt64(8192 * (1 + b % 3)))
        }
        tree.add(usr, "tool", .file, bytes: 65536)
        // Wide managed group through auxiliary volume roots.
        var urls = [systemURL, dataURL]
        for n in 0..<600 {
            let root = tree.root("/Volumes/V\(n)")
            urls.append(URL(fileURLWithPath: "/Volumes/V\(n)"))
            tree.add(root, "f", .file, bytes: UInt64(4096 * (1 + n % 4)))
        }
        return (tree, sysFolder, urls)
    }

    private func subjects() -> [Subject] {
        let fixture = driveTree()
        var result: [Subject] = []

        // Settled unified drive.
        let settled = settledResult(fixture.tree, roots: fixture.urls)
        func settledSubject(_ name: String, _ scope: Int?) -> Subject {
            let source = LogicalTreemapSource(
                base: CountingSource(base: SettledTreemapSource(result: settled)), namespace: settled.namespace,
                nodes: settled.nodes)
            let weight = scope.map { source.weight(of: $0) } ?? source.rootWeight
            source.base.counter.weights = 0
            source.base.counter.rows = 0
            return Subject(
                name: "settled \(name)", scope: scope, counter: source.base.counter,
                build: {
                    TreemapBuilder.build(
                        source: source, scope: scope, provisional: false, limits: $0, isCancelled: { false })
                },
                selectionCost: source.selectionCost(of: scope, limit: TreemapLimits.standard.maxPerFolder),
                weight: weight)
        }
        let merged = fixture.merged
        result += [
            settledSubject("root", nil), settledSubject("managed", managedGroup), settledSubject("merged", merged),
        ]

        // Provisional unified drive, built the way the scanner builds it.
        var index = ProgressiveIndex()
        admit(&index, fixture.tree.nodes, 0..<fixture.tree.nodes.count)
        let ns = index.logicalNamespace(nodes: fixture.tree.nodes, urls: fixture.urls, coverage: wholeDrive)
        var progress = ScanProgress()
        progress.state = .scanning
        func provisionalSubject(_ name: String, _ scope: Int?) -> Subject {
            let source = LogicalTreemapSource(
                base: CountingSource(
                    base: ProvisionalTreemapSource(
                        index: index, nodes: fixture.tree.nodes, urls: fixture.urls, coverage: wholeDrive,
                        progress: progress)), namespace: ns, nodes: fixture.tree.nodes)
            let weight = scope.map { source.weight(of: $0) } ?? source.rootWeight
            return Subject(
                name: "provisional \(name)", scope: scope, counter: source.base.counter,
                build: {
                    TreemapBuilder.build(
                        source: source, scope: scope, provisional: true, limits: $0, isCancelled: { false })
                },
                selectionCost: source.selectionCost(of: scope, limit: TreemapLimits.live.maxPerFolder), weight: weight)
        }
        result += [
            provisionalSubject("root", nil), provisionalSubject("managed", managedGroup),
            provisionalSubject("merged", merged),
        ]

        // Plain physical broad folder (no namespace), settled and provisional.
        var flat = Tree()
        let top = flat.root("Root")
        for n in 0..<5000 { flat.add(top, "f\(n % 40)-\(n).bin", .file, bytes: UInt64(4096 * (1 + n % 11))) }
        var flatProgress = ScanProgress()
        flatProgress.state = .completed
        let flatResult = ScanResult(
            id: UUID(), started: Date(), ended: Date(), roots: [URL(fileURLWithPath: "/Flat")],
            nodes: flat.settledNodes, progress: flatProgress, coverage: LocationCoverage(), volumes: [])
        let settledFlat = CountingSource(base: SettledTreemapSource(result: flatResult))
        result.append(
            Subject(
                name: "settled physical", scope: 0, counter: settledFlat.counter,
                build: {
                    TreemapBuilder.build(
                        source: settledFlat, scope: 0, provisional: false, limits: $0, isCancelled: { false })
                },
                selectionCost: settledFlat.selectionCost(of: 0, limit: TreemapLimits.standard.maxPerFolder),
                weight: settledFlat.weight(of: 0)))
        var flatIndex = ProgressiveIndex()
        admit(&flatIndex, flat.nodes, 0..<flat.nodes.count)
        let liveFlat = CountingSource(
            base: ProvisionalTreemapSource(
                index: flatIndex, nodes: flat.nodes, urls: [URL(fileURLWithPath: "/Flat")],
                coverage: LocationCoverage(), progress: progress))
        result.append(
            Subject(
                name: "provisional physical", scope: 0, counter: liveFlat.counter,
                build: {
                    TreemapBuilder.build(
                        source: liveFlat, scope: 0, provisional: true, limits: $0, isCancelled: { false })
                },
                selectionCost: liveFlat.selectionCost(of: 0, limit: TreemapLimits.live.maxPerFolder),
                weight: liveFlat.weight(of: 0)))
        for subject in result {
            subject.counter.weights = 0
            subject.counter.rows = 0
        }
        return result
    }

    private func expectExactArea(_ model: TreemapModel, weight: UInt64, _ note: String) {
        #expect(model.rootWeight == weight, "\(note): scope weight stays exact")
        for (index, tile) in model.tiles.enumerated() where tile.childCount > 0 {
            #expect(
                tile.children.reduce(UInt64(0)) { $0 + model.tiles[$1].weight } == tile.weight,
                "\(note): children of tile \(index)")
        }
        #expect(model.tiles.dropFirst().filter { $0.nodeID == LogicalNamespace.managedGroupID }.count <= 1)
    }

    @Test func totalReadsNeverExceedTheBudgetAtEveryScale() {
        for subject in subjects() {
            // Reads outside the ledger: the scope's own weight (and classification row), O(members) of one folder.
            subject.counter.weights = 0
            subject.counter.rows = 0
            subject.counter.infos = 0
            subject.counter.selected = 0
            subject.counter.sampled = 0
            _ = subject.build(TreemapLimits(maxCost: 0))
            let exempt = subject.counter.total
            #expect(exempt <= 4, "\(subject.name): only the scope's own reads happen at a zero budget")
            let budgets = [
                0, 1, max(0, subject.selectionCost - 1), subject.selectionCost, subject.selectionCost + 1,
                subject.selectionCost + 50,
                subject.selectionCost + 500, subject.selectionCost + 5_000,
            ]
            for budget in budgets {
                subject.counter.weights = 0
                subject.counter.rows = 0
                subject.counter.infos = 0
                subject.counter.selected = 0
                subject.counter.sampled = 0
                let limits = TreemapLimits(maxCost: budget)
                let model = subject.build(limits)
                let note = "\(subject.name) budget \(budget)"
                #expect(subject.counter.total <= budget + exempt, "\(note): counted \(subject.counter.total) reads")
                #expect(model.stats.cost <= budget, "\(note)")
                expectExactArea(model, weight: subject.weight, note)
                #expect(model.tiles.count <= limits.maxTiles, "\(note)")
                if budget < subject.selectionCost && subject.selectionCost > 0 {
                    // Selection is refused: the exact scope stays as one collapsed block, never a physical fallback.
                    #expect(
                        model.stats.limited && model.tiles.count == 2 && model.tiles[1].kind == .folderBlock
                            && model.tiles[1].weight == subject.weight, "\(note)")
                    #expect(model.tiles[1].nodeID == (subject.scope ?? -1), "\(note)")
                }
            }
            // Same inputs, same order: tie breaking and tiles are stable.
            let a = subject.build(TreemapLimits(maxCost: subject.selectionCost + 500))
            let b = subject.build(TreemapLimits(maxCost: subject.selectionCost + 500))
            #expect(
                a.tiles.map(\.nodeID) == b.tiles.map(\.nodeID) && a.tiles.map(\.weight) == b.tiles.map(\.weight),
                "\(subject.name)")
        }
    }

    @Test func unaffordableRowsLeaveTheirWeightInTheAggregateNotLost() {
        for subject in subjects() {
            // Enough for selection but not for every row: expansion stops, area is still exact.
            let rowless = subject.build(TreemapLimits(maxCost: subject.selectionCost))
            expectExactArea(rowless, weight: subject.weight, "\(subject.name) rows refused")
            let some = subject.build(TreemapLimits(maxCost: subject.selectionCost + 12))
            expectExactArea(some, weight: subject.weight, "\(subject.name) a few rows")
            #expect(some.tiles.count <= rowless.tiles.count + 40)
        }
    }

    @Test func selectionCostBoundsTheReadsSelectionPerforms() {
        for subject in subjects() where subject.scope != nil || subject.name.contains("root") {
            subject.counter.weights = 0
            subject.counter.rows = 0
            subject.counter.infos = 0
            subject.counter.selected = 0
            subject.counter.sampled = 0
            _ = subject.build(TreemapLimits(maxCost: 0))
            let exempt = subject.counter.total
            subject.counter.weights = 0
            subject.counter.rows = 0
            subject.counter.infos = 0
            subject.counter.selected = 0
            subject.counter.sampled = 0
            // Selection only: a budget that affords it but not a single row or tint.
            _ = subject.build(TreemapLimits(maxCost: subject.selectionCost))
            #expect(
                subject.counter.total <= subject.selectionCost + exempt,
                "\(subject.name): preflight must include member weights (\(subject.counter.total) vs \(subject.selectionCost))"
            )
        }
    }

    // MARK: Sampling

    /// 50 same-named real folders under one parent merge into one logical folder with 50 physical members.
    private func manyMembers() -> (result: ScanResult, primary: Int) {
        var tree = Tree()
        let system = tree.root("/")
        tree.root("/System/Volumes/Data")
        var primary = -1
        for n in 0..<50 {
            let id = tree.add(system, "Many")
            if n == 0 { primary = id }
        }
        let ids = tree.nodes.indices.filter { tree.nodes[$0].name == "Many" }
        for id in ids { for f in 0..<8 { tree.add(id, "f\(f).mov", .file, bytes: UInt64(4096 * (id + f + 1))) } }
        // Two members are empty or unavailable.
        tree.add(system, "Empty")
        tree.add(system, "Empty")
        return (settledResult(tree, roots: [systemURL, dataURL]), primary)
    }

    @Test func samplingSharesOneAllowanceAcrossAllPhysicalMembers() {
        let fixture = manyMembers()
        #expect(fixture.result.namespace.members[fixture.primary]?.count == 50)
        let source = LogicalTreemapSource(
            base: CountingSource(base: SettledTreemapSource(result: fixture.result)),
            namespace: fixture.result.namespace, nodes: fixture.result.nodes)
        for allowance in [0, 1, 7, 40] {
            source.base.counter.sampled = 0
            let sample = source.sampleCategories(under: fixture.primary, visits: allowance)
            #expect(
                sample.consumed <= allowance, "allowance \(allowance): consumed \(sample.consumed), not 50 × allowance")
            #expect(source.base.counter.sampled == sample.consumed)
            if allowance >= 8 { #expect(sample.categories?[.video, default: 0] ?? 0 > 0) }
        }
        // Empty and unavailable folders report nothing and consume at most their own probe.
        let empty = fixture.result.nodes.firstIndex { $0.name == "Empty" }!
        let none = source.sampleCategories(under: empty, visits: 40)
        #expect((none.categories?.isEmpty ?? true) && none.consumed <= 2)
        #expect(source.sampleCategories(under: managedGroup, visits: 40).consumed == 0)
    }

    @Test func buildDrawsSamplingFromTheRemainingGlobalBudget() {
        let fixture = manyMembers()
        for budget in [0, 5, 25, 60, 400, 5_000] {
            let counting = CountingSource(base: SettledTreemapSource(result: fixture.result))
            let source = LogicalTreemapSource(
                base: counting, namespace: fixture.result.namespace, nodes: fixture.result.nodes)
            _ = source.rootWeight
            counting.counter.weights = 0
            let reference = TreemapBuilder.build(
                source: source, scope: nil, provisional: false, limits: TreemapLimits(maxCost: 0),
                isCancelled: { false })
            let exempt = counting.counter.total
            counting.counter.weights = 0
            counting.counter.rows = 0
            counting.counter.infos = 0
            counting.counter.selected = 0
            counting.counter.sampled = 0
            let model = TreemapBuilder.build(
                source: source, scope: nil, provisional: false, limits: TreemapLimits(maxCost: budget),
                isCancelled: { false })
            #expect(counting.counter.total <= budget + exempt, "budget \(budget): \(counting.counter.total) reads")
            #expect(model.stats.cost <= budget && model.rootWeight == reference.rootWeight)
            // Sampling runs only when allowance remains, and never changes geometry or totals.
            if budget >= 5_000 { #expect(counting.counter.sampled <= 40 * model.stats.collapsedFolders) }
            for (index, tile) in model.tiles.enumerated() where tile.childCount > 0 {
                #expect(
                    tile.children.reduce(UInt64(0)) { $0 + model.tiles[$1].weight } == tile.weight,
                    "budget \(budget) tile \(index)")
            }
        }
    }

    // MARK: Ordering

    @Test func selectionBreaksWeightTiesByNameThenIDAtTheCut() {
        var tree = Tree()
        let root = tree.root("Root")
        // Equal weights everywhere; names out of order; two share a name.
        for name in ["delta", "alpha", "charlie", "bravo", "alpha", "echo", "alpha"] {
            tree.add(root, name, .file, bytes: 4096)
        }
        tree.add(root, "heavy", .file, bytes: 65536)
        var index = ProgressiveIndex()
        admit(&index, tree.nodes, 0..<tree.nodes.count)
        var progress = ScanProgress()
        progress.state = .scanning
        let provisional = ProvisionalTreemapSource(
            index: index, nodes: tree.nodes, urls: [URL(fileURLWithPath: "/Root")], coverage: LocationCoverage(),
            progress: progress)
        let settled = SettledTreemapSource(result: settledResult(tree, roots: [URL(fileURLWithPath: "/Root")]))
        func order(_ found: (items: [(id: Int, weight: UInt64)], total: Int, cost: Int)) -> [String] {
            found.items.map { tree.nodes[$0.id].name + "#\($0.id)" }
        }
        let expected = ["heavy#8", "alpha#2", "alpha#5", "alpha#7", "bravo#4", "charlie#3"]
        #expect(order(provisional.largestChildren(of: 0, limit: 6)) == expected)
        #expect(order(settled.largestChildren(of: 0, limit: 6)) == expected)
        // The cut keeps the lexically earliest equal-weight entries.
        #expect(order(provisional.largestChildren(of: 0, limit: 3)) == Array(expected.prefix(3)))
    }
}
