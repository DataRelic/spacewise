import CoreGraphics
import Foundation

/// How the storage map and the item list share the window's height. The map is the product; the list is the complete,
/// accessible equivalent. When there are only a few rows the map takes roughly 75–85 percent. The list never drops below
/// its header and two rows, and gains room as the window grows. Pure, so the arithmetic is tested without AppKit.
public enum SplitPolicy {
    public static let headerHeight: CGFloat = 28
    public static let rowHeight: CGFloat = 40
    /// Header plus two rows: the smallest list that is still useful (more rows scroll).
    public static let usefulList: CGFloat = headerHeight + 2 * rowHeight
    public static let minimumMap: CGFloat = 170
    /// A list this small shows only its header; used when the person collapses the list.
    public static let collapsedList: CGFloat = headerHeight + 2

    /// Height for the list part of a split of `available` points holding `rowCount` rows.
    public static func listHeight(rowCount: Int, available: CGFloat) -> CGFloat {
        guard available > 0 else { return usefulList }
        let desired = headerHeight + CGFloat(min(max(rowCount, 0), 14)) * rowHeight
        let cap: CGFloat = rowCount <= 6 ? 0.25 : (rowCount <= 10 ? 0.33 : (available >= 900 ? 0.36 : 0.38))
        let floorHeight = max(usefulList, available * 0.15)
        var list = min(max(desired, floorHeight), max(floorHeight, available * cap))
        if available - list < minimumMap { list = max(min(usefulList, available * 0.4), available - minimumMap) }
        return list.rounded()
    }
    public static func mapFraction(rowCount: Int, available: CGFloat) -> CGFloat {
        guard available > 0 else { return 0.5 }
        return (available - listHeight(rowCount: rowCount, available: available)) / available
    }
    /// Divider position measured from the top of the split (the map's height).
    public static func dividerPosition(rowCount: Int, available: CGFloat) -> CGFloat {
        (available - listHeight(rowCount: rowCount, available: available)).rounded()
    }
}
