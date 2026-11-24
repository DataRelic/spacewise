import AppKit

/// The app's type scale. Every label takes its font from here so sizes cannot drift between views.
///
/// Roles, not sizes: pick the role that matches what the text is, and add a role only when a new kind of
/// text appears. Anything that shows a number that can change (sizes, counts, percentages, durations) uses a
/// `numeric` variant so digits keep a fixed width and values do not shift as they update.
@MainActor
enum Typography {
    /// The one large headline on the Ready screen.
    static let hero = NSFont.systemFont(ofSize: 26, weight: .semibold)
    /// The name of the place being viewed, and sheet or panel titles.
    static let title = NSFont.systemFont(ofSize: 17, weight: .semibold)
    /// Section headings such as "Storage map" and inspector group names.
    static let heading = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// Primary text: row names, button-adjacent sentences, values.
    static let body = NSFont.systemFont(ofSize: 13)
    /// Supporting text: row subtitles, explanations, status lines.
    static let secondary = NSFont.systemFont(ofSize: 12)
    /// The smallest text: column headers, field labels, footnotes, map labels.
    static let caption = NSFont.systemFont(ofSize: 11)
    static let captionEmphasis = NSFont.systemFont(ofSize: 11, weight: .semibold)

    static let numericBody = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    /// A figure that is the point of its line, such as the totals in the scope header.
    static let numericBodyEmphasis = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    static let numericSecondary = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let numericCaption = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
}

/// The spacing grid. Insets, gaps and paddings come from these steps; do not introduce in-between values.
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}
