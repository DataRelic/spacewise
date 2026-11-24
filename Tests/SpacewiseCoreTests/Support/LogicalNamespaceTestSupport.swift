@testable import SpacewiseCore

extension LogicalNamespace {
    /// Every merged folder's logical children, materialized. Tests only: it rebuilds a dictionary on every read, so
    /// production pages through `page(for:offset:limit:)` instead.
    var mergedChildren: [Int: [Int]] { merged.mapValues(\.all) }
}
