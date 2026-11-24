import Foundation
import SpacewiseAppModel
import SpacewiseCore
import SpacewiseFixtures
import Testing

@MainActor @Suite struct ListQueryTests {
    private func names(_ rows: RowSource?) -> [String] {
        guard let rows else { return [] }
        return (0..<rows.count).compactMap { rows.row(at: $0)?.node.name }
    }

    @Test func columnDefaultsShowNameSizeShareAndItems() {
        let visible = ListColumn.allCases.filter(\.isVisibleByDefault)
        #expect(visible == [.name, .allocated, .share, .items])
        #expect(!ListColumn.logical.isVisibleByDefault)
        #expect(!ListColumn.classification.isVisibleByDefault)
        #expect(!ListColumn.operations.isVisibleByDefault)
        #expect(!ListColumn.name.canHide)
        let hideable = ListColumn.allCases.filter { $0 != .name }.allSatisfy { $0.canHide }
        #expect(hideable)
        #expect(!ListColumn.allCases.contains { $0.rawValue == "coverage" })
    }

    @Test func columnsSortByTheirOwnValue() {
        #expect(ListColumn.name.sortKey == .name && ListColumn.name.sortsAscendingFirst)
        #expect(ListColumn.allocated.sortKey == .allocated && !ListColumn.allocated.sortsAscendingFirst)
        #expect(ListColumn.share.sortKey == .allocated)
        #expect(ListColumn.items.sortKey == .items)
        #expect(ListColumn.classification.sortKey == nil)
    }

    @Test func anEmptyQueryLeavesTheSourceUntouched() {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let base = SettledRows(result: result, parent: 0)
        let cache = ListQueryCache()
        #expect(cache.rows(for: base, query: ListQuery()) === base)
        #expect(cache.rows(for: base, query: ListQuery(filter: "   ")) === base)
        #expect(ListQuery(filter: "  ").isIdentity)
    }

    @Test func theFilterMatchesNamesIgnoringCaseAndAccents() {
        let query = ListQuery(filter: " cafe ")
        #expect(query.matches("Café Photos"))
        #expect(query.matches("CAFETERIA"))
        #expect(!query.matches("Coffee"))
    }

    @Test func filteringKeepsOnlyMatchingRowsInSourceOrder() throws {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let base = SettledRows(result: result, parent: 0)
        let all = names(base)
        let needle = try #require(all.first).prefix(3).lowercased()
        let filtered = QueriedRows(base: base, query: ListQuery(filter: String(needle)))
        let expected = all.filter { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        #expect(names(filtered) == expected)
        #expect(!expected.isEmpty)
    }

    @Test func aFilterWithNoMatchesListsNothing() {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let filtered = QueriedRows(
            base: SettledRows(result: result, parent: 0), query: ListQuery(filter: "zzz-no-such"))
        #expect(filtered.count == 0)
        #expect(filtered.row(at: 0) == nil)
    }

    @Test func positionsAndNodesStayConsistentAfterSorting() {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let base = SettledRows(result: result, parent: 0)
        let sorted = QueriedRows(base: base, query: ListQuery(sort: ListSort(key: .name, ascending: true)))
        #expect(sorted.count == base.count)
        for index in 0..<sorted.count {
            let id = sorted.row(at: index)!.node.id
            #expect(sorted.index(ofNode: id) == index)
            #expect(sorted.node(at: index)?.id == id)
        }
        let ordered = names(sorted)
        #expect(ordered == ordered.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test(arguments: [ListSortKey.allocated, .logical], [true, false])
    func liveAndSettledSizesFollowMeasurements(key: ListSortKey, ascending: Bool) throws {
        let roots = [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/System/Volumes/Data")]
        var nodes = [
            ScanNode(id: 0, parent: nil, name: "/", kind: .directory, device: 1, inode: 1),
            ScanNode(id: 1, parent: nil, name: "Data", kind: .directory, device: 2, inode: 1),
            ScanNode(id: 2, parent: 0, name: "Users", kind: .directory, device: 1, inode: 2),
            ScanNode(id: 3, parent: 1, name: "Users", kind: .directory, device: 2, inode: 2),
            ScanNode(id: 4, parent: 2, name: "A Growing", kind: .directory, device: 1, inode: 3),
            ScanNode(id: 5, parent: 2, name: "Empty", kind: .file, device: 1, inode: 4),
            ScanNode(
                id: 6, parent: 2, name: "Sized", kind: .file, logicalBytes: 5120, allocatedBytes: 512,
                device: 1, inode: 5),
            ScanNode(id: 7, parent: 2, name: "B Alias", kind: .file, hardLinkOwner: 6, device: 1, inode: 5),
            ScanNode(
                id: 8, parent: 2, name: "C Cloud", kind: .file, logicalBytes: 16384,
                allocationUnknown: true, issue: .placeholder, device: 1, inode: 6),
            ScanNode(id: 9, parent: 2, name: "D Denied", kind: .directory, issue: .denied, device: 1, inode: 7),
        ]
        let cache = ListQueryCache()
        let query = ListQuery(sort: ListSort(key: key, ascending: ascending))
        var index = ProgressiveIndex()
        for node in nodes { index.append(node) }
        var coverage = LocationCoverage()
        coverage.enumeration = [
            0: .enumerated, 1: .enumerated, 2: .enumerated, 3: .enumerated,
            4: .unopened, 9: .openFailed,
        ]
        let id = UUID()
        var progress = ScanProgress()
        func live(_ revision: UInt64) -> SnapshotRows {
            SnapshotRows(
                index.snapshot(
                    scanID: id, revision: revision, request: ScopeRequest(parent: 2),
                    nodes: nodes, urls: roots, coverage: coverage, progress: progress))
        }
        func check(_ base: RowSource, expected: [Int]) throws {
            let rows = try #require(cache.rows(for: base, query: query))
            #expect((0..<rows.count).map { rows.node(at: $0)?.id } == expected)
        }

        let waiting = live(1)
        let growing = try #require(waiting.index(ofNode: 4))
        #expect(waiting.row(at: growing)?.coverage == .notYetScanned)
        let initial: [Int]
        let expected: [Int]
        if key == .allocated {
            initial = (ascending ? [5, 6] : [6, 5]) + [4, 7, 8, 9]
            expected = (ascending ? [5, 6, 4] : [4, 6, 5]) + [7, 8, 9]
        } else {
            initial = (ascending ? [5, 6, 8] : [8, 6, 5]) + [4, 7, 9]
            expected = (ascending ? [5, 4, 6, 8] : [8, 6, 4, 5]) + [7, 9]
        }
        try check(waiting, expected: initial)

        coverage.enumeration[4] = .partial
        let child = ScanNode(
            id: 10, parent: 4, name: "Child", kind: .file, logicalBytes: 64, allocatedBytes: 1024,
            device: 1, inode: 8)
        nodes.append(child)
        index.append(child)
        index.attribute(logical: 64, allocated: 1024, to: 4, nodes: nodes)
        let lowerBound = live(2)
        let partial = try #require(lowerBound.index(ofNode: 4))
        #expect(lowerBound.row(at: partial)?.coverage == .partial)
        try check(lowerBound, expected: expected)

        progress.state = .limited
        for enumeration: DirectoryEnumeration in [.partial, .enumerated] {
            coverage.enumeration[4] = enumeration
            var physicalNodes = nodes
            Scanner.finalizeCoverage(nodes: &physicalNodes, coverage: coverage)
            let physical = ScanResult(
                id: id, started: Date(), ended: Date(), roots: roots, nodes: physicalNodes,
                progress: progress, coverage: coverage, volumes: [])
            #expect(Array(physical.childIDs(of: 2)) == [4, 6, 5, 7, 8, 9])
            try check(SettledRows(result: physical, parent: 2), expected: expected)

            // Move a row to the Data twin so it can only appear in the settled query through the merge.
            var mergedNodes = nodes
            mergedNodes[8].parent = 3
            mergedNodes[8].device = 2
            var mergedCoverage = LocationCoverage(wholeDrive: true)
            mergedCoverage.enumeration = coverage.enumeration
            Scanner.finalizeCoverage(nodes: &mergedNodes, coverage: mergedCoverage)
            let merged = ScanResult(
                id: id, started: Date(), ended: Date(), roots: roots, nodes: mergedNodes,
                progress: progress, coverage: mergedCoverage, volumes: [])
            #expect(!merged.childIDs(of: 2).contains(8))
            #expect(merged.logicalChildIDs(of: 2).contains(8))
            #expect(merged.logicalRow(for: 4)?.coverage == (enumeration == .partial ? .partial : .measured))
            try check(SettledRows(result: merged, parent: 2), expected: expected)
        }
    }

    @Test func sortingByItemsPutsFilesLastInEitherDirection() throws {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let parent = try #require(
            result.nodes.map(\.id).first { id in
                let kids = result.logicalChildIDs(of: id)
                return kids.contains { result.itemCount(of: $0) != nil }
                    && kids.contains { result.itemCount(of: $0) == nil }
            })
        let base = SettledRows(result: result, parent: parent)
        for ascending in [true, false] {
            let rows = QueriedRows(
                base: base, query: ListQuery(sort: ListSort(key: .items, ascending: ascending)),
                itemCount: { result.itemCount(of: $0.id) })
            let counts = (0..<rows.count).map { rows.node(at: $0).flatMap { result.itemCount(of: $0.id) } }
            let firstFile = try #require(counts.firstIndex(of: nil))
            #expect(counts[firstFile...].allSatisfy { $0 == nil })
            let folders = counts[..<firstFile].compactMap { $0 }
            #expect(folders == (ascending ? folders.sorted() : folders.sorted(by: >)))
        }
    }

    @Test func theCacheKeepsOneObjectPerSourceAndQuery() throws {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let base = SettledRows(result: result, parent: 0)
        let cache = ListQueryCache()
        let query = ListQuery(filter: "a")
        let first = cache.rows(for: base, query: query)
        #expect(cache.rows(for: base, query: query) === first)
        let packageQuery = ListQuery(filter: ".app")
        let rootPackages = try #require(cache.rows(for: base, query: packageQuery))
        #expect(rootPackages !== first)
        #expect(rootPackages.count == 0)

        let applications = try #require(result.nodes.first { $0.name == "Applications" })
        let other = SettledRows(result: result, parent: applications.id)
        let packages = try #require(cache.rows(for: other, query: packageQuery))
        #expect(packages !== rootPackages)
        let expectedIDs = result.logicalChildIDs(of: applications.id)
        #expect(expectedIDs.count == 5)
        let actualIDs = (0..<packages.count).compactMap { packages.node(at: $0)?.id }
        #expect(packages.count == expectedIDs.count)
        #expect(Set(actualIDs) == Set(expectedIDs))
        #expect(cache.rows(for: nil, query: query) == nil)
    }

    @Test func itemCountsAreDirectEntriesOfFoldersOnly() throws {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let folder = try #require(result.logicalChildIDs(of: 0).first { result.node(for: $0)?.kind == .directory })
        #expect(result.itemCount(of: folder) == result.logicalChildIDs(of: folder).count)
        let file = try #require(result.nodes.first { $0.kind == .file })
        #expect(result.itemCount(of: file.id) == nil)
    }

    @Test func theManagedGroupCountsItsMembers() {
        let result = PresentationFixtures.wholeDrive(tailFiles: 50)
        let group = LogicalNamespace.managedGroupID
        #expect(result.itemCount(of: group) == result.logicalChildIDs(of: group).count)
        #expect((result.itemCount(of: group) ?? 0) > 0)
    }
}

@Suite struct ItemCountTests {
    @Test func aFolderThatCouldNotBeListedHasNoCount() throws {
        let result = PresentationFixtures.scenario(.limited).result
        let denied = try #require(result.nodes.first { $0.name == "Denied" })
        #expect(result.itemCount(of: denied.id) == nil)
    }
}
