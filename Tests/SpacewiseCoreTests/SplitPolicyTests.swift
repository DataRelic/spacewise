import Foundation
import Testing

@testable import SpacewiseCore

@Test(arguments: [0, 1, 2, 3, 4, 5, 6])
func fewRowsGiveTheMapRoughlyThreeQuartersToFourFifths(rows: Int) {
    for height in [560.0, 600.0, 720.0, 900.0, 1100.0] where height >= 560 {
        let fraction = SplitPolicy.mapFraction(rowCount: rows, available: height)
        let list = SplitPolicy.listHeight(rowCount: rows, available: height)
        #expect(list >= SplitPolicy.usefulList, "the list keeps its header and two rows")
        if height >= 600 { #expect(fraction >= 0.74 && fraction <= 0.86, "rows \(rows) at \(height): \(fraction)") }
    }
}

@Test func theListGrowsWithRowsAndNeverStarvesTheMap() {
    for height in [330.0, 450.0, 600.0, 800.0, 1100.0] {
        var previous: CGFloat = 0
        for rows in 0...30 {
            let list = SplitPolicy.listHeight(rowCount: rows, available: height)
            #expect(list >= previous, "list height must not shrink as rows are added (jitter)")
            previous = list
            #expect(
                height - list >= SplitPolicy.minimumMap - 0.5
                    || height < SplitPolicy.minimumMap + SplitPolicy.usefulList * 0.4)
            #expect(list >= min(SplitPolicy.usefulList, height * 0.4))
        }
        // Many rows: the map still dominates.
        #expect(SplitPolicy.mapFraction(rowCount: 30, available: height) >= 0.6)
    }
}

@Test func fullScreenGivesTheListMoreAbsoluteRoom() {
    let normal = SplitPolicy.listHeight(rowCount: 20, available: 600)
    let big = SplitPolicy.listHeight(rowCount: 20, available: 1100)
    #expect(big > normal + 100)
    #expect(
        SplitPolicy.mapFraction(rowCount: 20, available: 1100) > SplitPolicy.mapFraction(rowCount: 20, available: 600)
            - 0.04)
}

@Test func minimumWindowKeepsAUsefulListAndAUsableMap() {
    // 900 × 560 leaves roughly this much for the split once the toolbar, banner, header and footer are placed.
    for rows in [1, 3, 30] {
        let list = SplitPolicy.listHeight(rowCount: rows, available: 330)
        #expect(list >= SplitPolicy.usefulList)
        #expect(330 - list >= SplitPolicy.minimumMap - 12)
    }
}

@Test func dividerPositionMatchesTheMapHeight() {
    #expect(
        SplitPolicy.dividerPosition(rowCount: 3, available: 640) == 640
            - SplitPolicy.listHeight(rowCount: 3, available: 640))
}
