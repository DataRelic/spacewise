/// The item list's columns, in display order. The raw value is the table column identifier, which the table's saved
/// layout is stored under, so existing raw values must not change.
public enum ListColumn: String, CaseIterable, Sendable {
    case name, allocated, logical, share, items, classification, operations

    /// Shown until the person changes it from the header's menu.
    public var isVisibleByDefault: Bool {
        switch self {
        case .name, .allocated, .share, .items: true
        case .logical, .classification, .operations: false
        }
    }

    /// The name column identifies the row, so it cannot be hidden.
    public var canHide: Bool { self != .name }

    /// What a click on this column's header sorts by; nil when the column does not sort.
    public var sortKey: ListSortKey? {
        switch self {
        case .name: .name
        case .allocated, .share: .allocated
        case .logical: .logical
        case .items: .items
        case .classification, .operations: nil
        }
    }

    /// The direction a first click sorts in: names A to Z, numbers largest first.
    public var sortsAscendingFirst: Bool { self == .name }
}
