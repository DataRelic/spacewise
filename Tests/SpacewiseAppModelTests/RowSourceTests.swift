import Foundation
import SpacewiseAppModel
import SpacewiseCore
import SpacewiseFixtures
import Testing

@MainActor @Suite struct RowSourceTests {
    @Test func settledRowsCountFromZeroOverASliceOfTheSharedIndex() throws {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        // A nested folder's children sit in the middle of the shared index, so the slice does not start at 0.
        let folder = try #require(result.logicalChildIDs(of: 0).first { result.logicalChildIDs(of: $0).count > 1 })
        let rows = SettledRows(result: result, parent: folder)
        let ids = result.logicalChildIDs(of: folder)
        #expect(ids.startIndex > 0)
        #expect(rows.count == ids.count)
        #expect(rows.row(at: 0)?.node.id == ids.first)
        #expect(rows.row(at: rows.count - 1)?.node.id == ids.last)
        for (position, id) in ids.enumerated() {
            #expect(rows.index(ofNode: id) == position)
            #expect(rows.row(at: position)?.node.id == id)
        }
    }

    @Test func settledRowsRejectPositionsOutsideTheList() {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let rows = SettledRows(result: result, parent: 0)
        #expect(rows.row(at: -1) == nil)
        #expect(rows.row(at: rows.count) == nil)
        #expect(rows.row(at: rows.count + 10) == nil)
    }

    @Test func settledRowsDoNotFindNodesListedElsewhere() throws {
        let result = PresentationFixtures.storageMap(tailFiles: 50)
        let rows = SettledRows(result: result, parent: 0)
        let child = try #require(result.logicalChildIDs(of: 0).first)
        let grandchild = try #require(result.logicalChildIDs(of: child).first)
        #expect(rows.index(ofNode: grandchild) == nil)
        #expect(rows.index(ofNode: 0) == nil)
        #expect(rows.index(ofNode: -5) == nil)
    }

    @Test func emptyFolderHasNoRows() {
        let fixture = PresentationFixtures.scenario(.empty)
        let rows = SettledRows(result: fixture.result, parent: 0)
        #expect(rows.count == 0)
        #expect(rows.row(at: 0) == nil)
    }

    @Test func snapshotRowsFollowTheSnapshotOrder() throws {
        let snapshot = PresentationFixtures.scenario(.scanning).snapshot
        let rows = SnapshotRows(snapshot)
        #expect(rows.count == snapshot.rows.count)
        let last = try #require(snapshot.rows.last)
        #expect(rows.index(ofNode: last.node.id) == snapshot.rows.count - 1)
        #expect(rows.row(at: 0)?.node.id == snapshot.rows.first?.node.id)
        #expect(rows.row(at: -1) == nil)
        #expect(rows.row(at: snapshot.rows.count) == nil)
        #expect(rows.index(ofNode: Int.max) == nil)
    }
}
