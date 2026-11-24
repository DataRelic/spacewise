import Foundation

/// Copy and formatting for the storage map. Pure, so tests can check that the map never overclaims:
/// it shows allocated size, says what was summed or left as blocks, and treats unread items as unknown.
public enum TreemapPresentation {
    public struct TileDetail: Sendable, Equatable {
        public let title: String
        public let kind: String
        public let size: SizeText
        /// Share of the whole map (the scope), when meaningful.
        public let share: Double?
        public let category: String
        public let accessibility: String
    }

    /// One honest paragraph under the map: what area means, what is individually drawn, what is summed.
    public static func disclosure(_ model: TreemapModel) -> String {
        let stats = model.stats
        var parts = ["A tile’s area is proportional to its allocated size on disk."]
        if model.provisional {
            parts.append("The scan is still counting, so the map shows the allocated space found so far.")
        }
        let drawn = SizeFormat.count(UInt64(stats.itemsDrawn))
        let individual = Plural.word(stats.itemsDrawn, "individual tile", "individual tiles")
        parts.append("The map shows \(drawn) \(individual).")
        if stats.aggregates > 0 {
            let grouped = SizeFormat.count(UInt64(stats.itemsGrouped))
            let groups = SizeFormat.count(UInt64(stats.aggregates))
            parts.append(
                "\(grouped) smaller \(Plural.word(stats.itemsGrouped, "entry is", "entries are")) added together in "
                    + "\(groups) \(Plural.word(stats.aggregates, "group tile", "group tiles"))."
            )
        }
        if stats.collapsedFolders > 0 {
            let folders = Plural.word(stats.collapsedFolders, "folder appears", "folders each appear")
            parts.append("\(SizeFormat.count(UInt64(stats.collapsedFolders))) \(folders) as one hatched block.")
        } else if stats.folders > 0 {
            let folders = Plural.word(stats.folders, "folder is", "folders are")
            parts.append("\(SizeFormat.count(UInt64(stats.folders))) \(folders) shown with contents.")
        }
        if model.tiles.contains(where: { $0.managed }) {
            parts.append(
                "The woven blue group contains items that macOS manages. Each entry has its own location."
            )
        }
        parts.append(
            "File Types accounts for all allocated space drawn on the map. Expanded folders contribute through their contents. Unopened folder blocks, smaller-item groups and macOS-managed space have separate rows. Estimated block and group colors don’t change those totals."
        )
        if stats.partialTiles > 0 || model.provisional {
            parts.append("Items that were only partly read say so in their details.")
        }
        parts.append(
            "Only measured allocation takes up area. Use the Item List to see direct entries, including those without a tile, and open folders to browse their contents."
        )
        return parts.joined(separator: " ")
    }

    /// Compact header line.
    public static func summary(_ model: TreemapModel) -> String {
        // The folder's size is in the scope header above; this line says only what the map itself shows.
        guard !model.isEmpty else { return model.provisional ? "Nothing sized yet" : "Nothing to draw" }
        let drawn = model.stats.itemsDrawn
        var text = "\(SizeFormat.count(UInt64(drawn))) individual \(Plural.word(drawn, "tile", "tiles"))"
        let grouped = model.stats.itemsGrouped
        if grouped > 0 {
            text +=
                " · \(SizeFormat.count(UInt64(grouped))) smaller \(Plural.word(grouped, "entry", "entries")) grouped"
        }
        return text
    }

    public static func detail(tile index: Int, in model: TreemapModel) -> TileDetail? {
        guard model.tiles.indices.contains(index) else { return nil }
        let tile = model.tiles[index]
        let size = SizeText.make(
            known: tile.weight,
            partial: tile.partial || model.provisional && tile.kind != .file && tile.kind != .package)
        let share = model.rootWeight > 0 && index != 0 ? Double(tile.weight) / Double(model.rootWeight) : nil
        var kind: String
        let title: String
        switch tile.kind {
        case .aggregate:
            kind = "Group of smaller items"
            let items = Plural.word(tile.itemCount, "item", "items")
            title = "\(SizeFormat.count(UInt64(tile.itemCount))) smaller \(items)"
        case .folder:
            kind = "Folder"
            title = model.rows[index]?.node.name ?? "Folder"
        case .folderBlock:
            kind = "Folder (shown as one block)"
            title = model.rows[index]?.node.name ?? "Folder"
        case .package:
            kind = "Package"
            title = model.rows[index]?.node.name ?? "Package"
        case .file:
            kind = "File"
            title = model.rows[index]?.node.name ?? "File"
        }
        if tile.managed { kind += " · managed by macOS" }
        let percent = share.map(ShareFormat.spoken)
        let categoryText =
            tile.managed && tile.kind == .folder
            ? FileCategory.managedZone.title
            : (tile.kind == .folder ? "Folder, contents shown" : tile.category.title)
        let spoken = [
            title + ", " + kind.lowercased(), size.spoken, percent.map { $0 + " of this view" },
            categoryText.lowercased(),
        ]
        .compactMap { $0 }.joined(separator: ", ")
        return TileDetail(
            title: title, kind: kind, size: size, share: share, category: categoryText, accessibility: spoken)
    }

    /// One-line readout under the map for hover and selection.
    public static func readout(tile index: Int, in model: TreemapModel, path: String? = nil) -> String {
        guard let detail = detail(tile: index, in: model) else { return "" }
        var parts = [detail.title, detail.kind, detail.size.text]
        if let share = detail.share { parts.append(ShareFormat.percent(share) + " of this view") }
        parts.append(detail.category)
        if let path { parts.append(path) }
        return parts.joined(separator: "  ·  ")
    }

    /// Inspector fields for a selected aggregate tile.
    public static func aggregateFields(
        tile index: Int, in model: TreemapModel, folderName: String?,
        folderPath: String?
    ) -> [InspectorField] {
        guard let detail = detail(tile: index, in: model) else { return [] }
        let tile = model.tiles[index]
        var fields = [
            InspectorField(label: "Name", value: detail.title),
            InspectorField(label: "Kind", value: detail.kind),
        ]
        fields.append(InspectorField(label: "Inside", value: folderPath ?? folderName ?? "The scope shown"))
        fields.append(
            InspectorField(
                label: "Size, together",
                value: "\(detail.size.text) (\(SizeFormat.exact(tile.weight)))"))
        if let share = detail.share {
            fields.append(InspectorField(label: "Share of view", value: ShareFormat.percent(share)))
        }
        fields.append(
            InspectorField(
                label: "Why it is a group",
                value:
                    "Each of these items is too small to draw, so their sizes are added together here and nothing is left out. Open the folder, or use the list, to see each one."
            ))
        if model.provisional {
            fields.append(
                InspectorField(label: "Status", value: "Still counting. Sizes can grow until the scan finishes."))
        }
        return fields
    }
}
