import Foundation
import Testing

@testable import SpacewiseCore

/// Every share in the UI goes through one rule: one decimal, and a share under a tenth of a percent says so rather
/// than rounding to zero.
struct ShareFormatTests {
    @Test func visibleAndSpokenFormsAgree() {
        #expect(ShareFormat.percent(0.123) == "12.3%")
        #expect(ShareFormat.spoken(0.123) == "12.3 percent")
        #expect(ShareFormat.percent(1) == "100.0%")
        #expect(ShareFormat.percent(0.001) == "0.1%")
        #expect(ShareFormat.percent(0.000_999) == "< 0.1%")
        #expect(ShareFormat.spoken(0.000_999) == "less than 0.1 percent")
        #expect(ShareFormat.percent(0) == "< 0.1%")
    }

    private func tinyAggregateModel() -> TreemapModel {
        func tile(
            _ node: Int, parent: Int, kind: TreemapTile.Kind, weight: UInt64, first: Int = 0,
            count: Int = 0
        ) -> TreemapTile {
            TreemapTile(
                nodeID: node, parent: parent, kind: kind, category: kind == .aggregate ? .grouped : .other,
                weight: weight, depth: parent < 0 ? 0 : 1, firstChild: first, childCount: count,
                partial: false, itemCount: kind == .aggregate ? 40 : 0, managed: false, tint: nil)
        }
        let tiles = [
            tile(-1, parent: -1, kind: .folder, weight: 1_000_000, first: 1, count: 2),
            tile(0, parent: 0, kind: .file, weight: 999_999),
            tile(-1, parent: 0, kind: .aggregate, weight: 1),
        ]
        return TreemapModel(scope: nil, provisional: false, tiles: tiles, rows: [nil, nil, nil], stats: TreemapStats())
    }

    @Test func mapReadoutSpokenDetailAndInspectorUseTheSameRule() throws {
        let model = tinyAggregateModel()
        #expect(TreemapPresentation.readout(tile: 2, in: model).contains("< 0.1% of this view"))
        let detail = try #require(TreemapPresentation.detail(tile: 2, in: model))
        #expect(detail.accessibility.contains("less than 0.1 percent of this view"))
        let share = TreemapPresentation.aggregateFields(tile: 2, in: model, folderName: nil, folderPath: nil)
            .first { $0.label == "Share of view" }
        // Was "0.0%": the inspector used no threshold.
        #expect(share?.value == "< 0.1%")
        let big = TreemapPresentation.aggregateFields(tile: 1, in: model, folderName: nil, folderPath: nil)
            .first { $0.label == "Share of view" }
        #expect(big?.value == "100.0%")
    }

    @Test func rowAccessibilityUsesTheSameRule() {
        func spoken(allocated: UInt64, of scope: UInt64) -> String {
            var node = ScanNode(id: 1, parent: 0, name: "a.bin", kind: .file, device: 1, inode: 1)
            node.allocatedBytes = allocated
            node.logicalBytes = allocated
            let row = ScopeRow(node: node, classification: .personal, coverage: .measured, enumeration: nil)
            return RowPresentation(row: row, provisional: false, scopeAllocated: scope).accessibility
        }
        // Was "12 percent" and "0 percent": whole percents with no threshold.
        #expect(spoken(allocated: 123, of: 1000).contains("12.3 percent of this folder"))
        #expect(spoken(allocated: 1, of: 1_000_000).contains("less than 0.1 percent of this folder"))
    }
}

struct PluralTests {
    @Test func onlyExactlyOneIsSingular() {
        #expect(Plural.word(1, "item", "items") == "item")
        #expect(Plural.word(0, "item", "items") == "items")
        #expect(Plural.word(UInt64(2), "item", "items") == "items")
    }

    @Test func existingWordingIsUnchanged() {
        #expect(SizeFormat.bytes(1) == "1 byte")
        #expect(SizeFormat.bytes(2) == "2 bytes")
        #expect(SizeFormat.exact(1) == "1 byte")
        #expect(SizeFormat.exact(1_234) == "\(1_234.formatted()) bytes")
        #expect(SizeFormat.age(60) == "1 minute" && SizeFormat.age(150) == "2 minutes")
        #expect(SizeFormat.age(3600) == "1 hour" && SizeFormat.age(7200) == "2 hours")
        #expect(SizeFormat.age(86_400) == "1 day" && SizeFormat.age(172_800) == "2 days")
        let one = ScopeHeaderPresentation(
            summary: ScopeSummary(
                crumbs: [], logicalBytes: 0, allocatedBytes: 0,
                allocationUnknown: false, issue: nil, enumeration: nil),
            provisional: false, total: 1)
        #expect(one.itemsText == "1")
    }
}

struct ElapsedTimeTests {
    @Test func durationsBecomeFractionalSeconds() {
        #expect(Duration.seconds(2).totalSeconds == 2)
        #expect(Duration.milliseconds(1500).totalSeconds == 1.5)
        #expect(Duration.zero.totalSeconds == 0)
    }
}

struct StartupDrivePathTests {
    @Test func dataVolumePathsAreShownRootedAtSlash() {
        #expect(StartupDrive.dataVolumePath == "/System/Volumes/Data")
        #expect(StartupDrive.logicalPath("/System/Volumes/Data") == "/")
        #expect(StartupDrive.logicalPath("/System/Volumes/Data/Users/me") == "/Users/me")
        #expect(StartupDrive.logicalPath("/System/Volumes/DataOther") == "/System/Volumes/DataOther")
        #expect(StartupDrive.logicalPath("/Users") == "/Users")
    }
}
