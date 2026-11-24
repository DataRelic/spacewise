import AppKit
import SpacewiseCore

/// A label drawn over the storage map: a folder pill, or a leaf tile's name and size.
struct TreemapLabel {
    let rect: CGRect
    let title: String
    let subtitle: String?
    /// Dark ink (on light fills).
    let dark: Bool
    let pill: Bool
    /// The translucent plate that lifts contrast to AA where the bare fill is mid-tone.
    var scrim: Double = 0
    /// Marks the system-managed pill (steel plate and a lock).
    var managed = false
    /// The tile the label names: the folder a pill stands for, or a leaf; nil for the zoomed-in managed banner.
    var tile: Int? = nil
}

/// Chooses which labels fit on a laid-out map.
@MainActor enum TreemapLabelPlanner {
    static let pillFont = Typography.captionEmphasis
    /// The most leaf labels drawn, largest tiles first.
    private static let maximumLeafLabels = 260

    static func plan(model: TreemapModel, layout: TreemapLayout, dark: Bool) -> [TreemapLabel] {
        let pills = folderPills(model: model, layout: layout)
        let leaves = leafLabels(model: model, layout: layout, dark: dark, avoiding: pills)
        return leaves + pills
    }

    /// Pills for the biggest folders near the top of the hierarchy: orientation without opening anything.
    private static func folderPills(model: TreemapModel, layout: TreemapLayout) -> [TreemapLabel] {
        var pills: [TreemapLabel] = []
        var pillDepth: [String: Int] = [:]
        for (index, tile) in model.tiles.enumerated() where tile.kind == .folder && index > 0 && tile.depth <= 2 {
            let rect = layout.rects[index]
            guard rect.width >= (tile.depth == 1 ? 96 : 150),
                rect.height >= (tile.depth == 1 ? 44 : 64),
                let name = model.rows[index]?.node.name
            else { continue }
            let size = SizeFormat.bytes(tile.weight)
            let isGroup = tile.nodeID == LogicalNamespace.managedGroupID
            let text = "\(name)  \(tile.partial ? "≥ " : "")\(size)"
            let measured = (text as NSString).size(withAttributes: [.font: pillFont]).width
            let width = min(rect.width - 2 * Spacing.s, measured + (isGroup ? 30 : 2 * Spacing.s))
            let key = "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded()))"
            // Nested folders share a corner; label only the deepest one that fits so pills never stack.
            // The system-managed group's pill always wins its corner: it is the one label that must never be hidden.
            let rank = isGroup ? 99 : tile.depth
            if let existing = pillDepth[key], existing >= rank { continue }
            if pillDepth[key] != nil {
                pills.removeAll {
                    "\(Int(($0.rect.minX - Spacing.s).rounded())),\(Int(($0.rect.minY - Spacing.s).rounded()))" == key
                }
            }
            pillDepth[key] = rank
            let pillRect = CGRect(x: rect.minX + Spacing.s, y: rect.minY + Spacing.s, width: width, height: 18)
            pills.append(
                TreemapLabel(
                    rect: pillRect, title: text, subtitle: nil, dark: false, pill: true,
                    managed: isGroup, tile: index))
        }
        // Zoomed inside system-managed content: the whole map is the protected region, so say so once.
        if let first = model.tiles.first, first.managed {
            let text = LogicalNamespace.managedGroupName
            let width = (text as NSString).size(withAttributes: [.font: pillFont]).width + 30
            pills.append(
                TreemapLabel(
                    rect: CGRect(x: Spacing.s, y: Spacing.s, width: width, height: 18), title: text, subtitle: nil,
                    dark: false, pill: true, managed: true, tile: nil))
        }
        return pills
    }

    /// Names (and sizes where there is room) on leaf tiles that a pill does not cover.
    private static func leafLabels(
        model: TreemapModel, layout: TreemapLayout, dark: Bool,
        avoiding pills: [TreemapLabel]
    ) -> [TreemapLabel] {
        var leafLabels: [(area: CGFloat, label: TreemapLabel)] = []
        for (index, tile) in model.tiles.enumerated() where index > 0 && tile.isLeaf {
            let rect = layout.rects[index]
            guard rect.width >= 56, rect.height >= 16 else { continue }
            let title: String
            if tile.kind == .aggregate {
                title = ProductCopy.Map.smallerItems(SizeFormat.count(UInt64(tile.itemCount)))
            } else {
                title = model.rows[index]?.node.name ?? ""
            }
            guard !title.isEmpty else { continue }
            let inner = rect.insetBy(dx: Spacing.xs, dy: Spacing.xs)
            if pills.contains(where: { $0.rect.intersects(inner) }) { continue }
            let style = TreemapPalette.label(on: TreemapPalette.fill(tile, dark: dark))
            let hasRoomForSize = rect.height >= 34 && rect.width >= 66
            let subtitle = hasRoomForSize ? (tile.partial ? "≥ " : "") + SizeFormat.bytes(tile.weight) : nil
            let label = TreemapLabel(
                rect: inner, title: title, subtitle: subtitle, dark: style.darkInk, pill: false,
                scrim: style.scrim, tile: index)
            leafLabels.append((rect.width * rect.height, label))
        }
        leafLabels.sort { $0.area > $1.area }
        return leafLabels.prefix(maximumLeafLabels).map(\.label)
    }
}
