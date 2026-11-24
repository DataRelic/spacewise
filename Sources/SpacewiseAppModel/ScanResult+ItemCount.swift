import SpacewiseCore

extension ScanResult {
    /// The number of entries directly inside a folder or package, as the list would show them when it is opened;
    /// nil for anything else, and for a folder whose listing was not read in full (its count is unknown, not zero).
    /// Reads the shared index, so it is cheap enough to call per row.
    public func itemCount(of id: Int) -> Int? {
        guard let node = logicalNode(for: id), node.kind == .directory || node.kind == .package else { return nil }
        if let list = namespace.listCount(for: id) { return list }
        guard node.issue == nil, coverage.enumeration[id].map({ $0 == .enumerated }) ?? true else { return nil }
        return childIDs(of: id).count
    }
}
