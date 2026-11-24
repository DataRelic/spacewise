import AppKit
import SpacewiseAppModel
import SpacewiseCore

/// The hover card's content: a title, detail lines and an optional path (truncated in the middle).
struct HoverCard {
    let title: String
    let lines: [String]
    let path: String?
}

/// The overlays drawn over the storage map's bitmap: type-highlight wash, the managed group's frame, labels, the
/// hovered tile's folder, hover and selection outlines, and the detail card. Each function draws into the current
/// graphics context of a flipped view. Fonts, paragraph styles and attributes are built once, not per label per draw.
@MainActor enum TreemapDrawing {
    /// The managed group's frame: a solid steel stroke.
    static let groupFrameColor = NSColor(srgbRed: 0.30, green: 0.42, blue: 0.70, alpha: 0.95)
    /// The managed group's pill plate.
    static let managedPillColor = NSColor(srgbRed: 0.16, green: 0.25, blue: 0.46, alpha: 0.94)

    /// The system display settings the overlays follow.
    struct Style {
        /// Reduce Transparency or Increase Contrast: plates, the card and the type wash are drawn opaque.
        var opaque = false
        /// Increase Contrast: stronger card border and outlines.
        var highContrast = false

        static var current: Style {
            let workspace = NSWorkspace.shared
            let contrast = workspace.accessibilityDisplayShouldIncreaseContrast
            return Style(
                opaque: contrast || workspace.accessibilityDisplayShouldReduceTransparency,
                highContrast: contrast)
        }
    }

    // MARK: Text attributes, built once

    private static let truncatingTail: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return paragraph
    }()
    private static let truncatingMiddle: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        return paragraph
    }()
    private static let pillAttributes: [NSAttributedString.Key: Any] = [
        .font: Typography.captionEmphasis, .foregroundColor: NSColor.white, .paragraphStyle: truncatingTail,
    ]
    /// Leaf label text: white ink with a dark halo, or dark ink with a light halo.
    private static func leafAttributes(darkInk: Bool, subtitle: Bool) -> [NSAttributedString.Key: Any] {
        switch (darkInk, subtitle) {
        case (false, false): lightTitle
        case (false, true): lightSubtitle
        case (true, false): darkTitle
        case (true, true): darkSubtitle
        }
    }
    private static func makeLeafAttributes(darkInk: Bool, subtitle: Bool) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = .zero
        shadow.shadowColor = darkInk ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.85)
        let ink: NSColor = darkInk ? NSColor(white: 0.08, alpha: 0.96) : .white
        return [
            .font: subtitle ? Typography.numericCaption : Typography.captionEmphasis,
            .foregroundColor: subtitle ? ink.withAlphaComponent(0.9) : ink,
            .paragraphStyle: truncatingTail, .shadow: shadow,
        ]
    }
    private static let lightTitle = makeLeafAttributes(darkInk: false, subtitle: false)
    private static let lightSubtitle = makeLeafAttributes(darkInk: false, subtitle: true)
    private static let darkTitle = makeLeafAttributes(darkInk: true, subtitle: false)
    private static let darkSubtitle = makeLeafAttributes(darkInk: true, subtitle: true)
    private static let cardTitleAttributes: [NSAttributedString.Key: Any] = [
        .font: Typography.heading, .foregroundColor: NSColor.labelColor, .paragraphStyle: truncatingTail,
    ]
    private static let cardBodyAttributes: [NSAttributedString.Key: Any] = [
        .font: Typography.caption, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: truncatingTail,
    ]
    private static let cardPathAttributes: [NSAttributedString.Key: Any] = [
        .font: Typography.caption, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: truncatingMiddle,
    ]
    /// Line heights of the two text roles on the map.
    private static let captionLine: CGFloat = 14
    private static let headingLine: CGFloat = 17

    // MARK: Shapes

    /// Type highlight: wash every leaf that is not of the chosen type. Esc or the type list restores.
    static func wash(
        _ model: TreemapModel, _ layout: TreemapLayout, except category: FileCategory, backdrop: NSColor,
        style: Style, in dirtyRect: NSRect
    ) {
        backdrop.withAlphaComponent(style.opaque ? 0.86 : 0.66).setFill()
        for (index, tile) in model.tiles.enumerated()
        where index > 0 && tile.isLeaf && !LegendFocus.matches(tile, category) {
            let rect = layout.rects[index]
            if rect.intersects(dirtyRect) { rect.fill() }
        }
    }

    /// The protected region: a solid steel frame with a dashed inner line, so it reads without relying on colour.
    static func groupFrame(_ rect: CGRect) {
        let outer = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        outer.lineWidth = 2
        groupFrameColor.setStroke()
        outer.stroke()
        let inner = NSBezierPath(rect: rect.insetBy(dx: 3.5, dy: 3.5))
        inner.lineWidth = 1
        inner.setLineDash([5, 3], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.75).setStroke()
        inner.stroke()
    }

    /// A white line over a dark one, so the outline reads on any fill.
    static func outline(_ rect: CGRect, white: CGFloat, width: CGFloat, shadow: CGFloat) {
        let inset = width * 0.5 - 0.5
        let outer = NSBezierPath(rect: rect.insetBy(dx: inset, dy: inset))
        outer.lineWidth = width + 2
        NSColor.black.withAlphaComponent(shadow).setStroke()
        outer.stroke()
        let inner = NSBezierPath(rect: rect.insetBy(dx: inset, dy: inset))
        inner.lineWidth = width
        NSColor.white.withAlphaComponent(white).setStroke()
        inner.stroke()
    }

    /// The folder holding the hovered tile: a dashed white line over a dark one, lighter than the tile's own outline so
    /// the two read as "this item, in this folder".
    static func folderOutline(_ rect: CGRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        path.lineWidth = 3
        NSColor.black.withAlphaComponent(0.4).setStroke()
        path.stroke()
        path.lineWidth = 1.5
        path.setLineDash([6, 3], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }

    // MARK: Labels

    static func label(_ label: TreemapLabel, style: Style) {
        if label.pill {
            pill(label, style: style)
        } else {
            leaf(label, style: style)
        }
    }

    private static func pill(_ label: TreemapLabel, style: Style) {
        let plate = label.managed ? managedPillColor : NSColor.black.withAlphaComponent(0.62)
        (style.opaque ? plate.withAlphaComponent(1) : plate).setFill()
        let shape = NSBezierPath(roundedRect: label.rect, xRadius: 5, yRadius: 5)
        shape.fill()
        var textRect = label.rect.insetBy(dx: Spacing.s, dy: 2)
        if label.managed {
            NSColor.white.withAlphaComponent(0.85).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            if let lock = lockSymbol {
                let size = lock.size
                let lockRect = CGRect(
                    x: label.rect.minX + 7, y: label.rect.midY - size.height / 2,
                    width: size.width, height: size.height)
                lock.draw(
                    in: lockRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            textRect = CGRect(
                x: label.rect.minX + 21, y: label.rect.minY + 2,
                width: label.rect.width - 26, height: label.rect.height - 4)
        }
        (label.title as NSString).draw(in: textRect, withAttributes: pillAttributes)
    }

    private static let lockSymbol: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: Typography.captionEmphasis.pointSize, weight: .bold, scale: .small
        )
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }()

    private static func leaf(_ label: TreemapLabel, style: Style) {
        let titleAttributes = leafAttributes(darkInk: label.dark, subtitle: false)
        let subtitleAttributes = leafAttributes(darkInk: label.dark, subtitle: true)
        if label.scrim > 0 {
            let titleWidth = (label.title as NSString).size(withAttributes: titleAttributes).width
            let subtitleWidth =
                label.subtitle.map {
                    ($0 as NSString).size(withAttributes: subtitleAttributes).width
                } ?? 0
            let widest = max(titleWidth, subtitleWidth)
            let plate = CGRect(
                x: label.rect.minX - 2, y: label.rect.minY - 1, width: min(label.rect.width + 4, widest + 8),
                height: label.subtitle == nil ? captionLine + 2 : 2 * captionLine + 2)
            let scrim = style.opaque ? max(label.scrim, 0.5) : label.scrim
            (label.dark ? NSColor.white : NSColor.black).withAlphaComponent(scrim).setFill()
            NSBezierPath(roundedRect: plate, xRadius: 4, yRadius: 4).fill()
        }
        let titleRect = CGRect(x: label.rect.minX, y: label.rect.minY, width: label.rect.width, height: captionLine)
        (label.title as NSString).draw(in: titleRect, withAttributes: titleAttributes)
        if let sub = label.subtitle {
            let subtitleRect = CGRect(
                x: label.rect.minX, y: label.rect.minY + captionLine, width: label.rect.width,
                height: captionLine)
            (sub as NSString).draw(in: subtitleRect, withAttributes: subtitleAttributes)
        }
    }

    // MARK: Card

    /// The detail card near `point`, flipped to the other side of the point when it would leave `bounds`.
    static func card(_ content: HoverCard, at point: CGPoint, in bounds: CGRect, style: Style) {
        var lines: [(text: String, attributes: [NSAttributedString.Key: Any], height: CGFloat)] = [
            (content.title, cardTitleAttributes, headingLine)
        ]
        lines += content.lines.map { ($0, cardBodyAttributes, captionLine + 2) }
        if let path = content.path { lines.append((path, cardPathAttributes, captionLine + 2)) }
        let widest = lines.map { ($0.text as NSString).size(withAttributes: $0.attributes).width }.max() ?? 180
        let width = min(360, max(180, widest) + 2 * Spacing.m)
        let height = lines.reduce(0) { $0 + $1.height } + 2 * Spacing.s
        var origin = CGPoint(x: point.x + Spacing.l, y: point.y + Spacing.l)
        if origin.x + width > bounds.maxX - Spacing.xs { origin.x = point.x - width - Spacing.m }
        if origin.y + height > bounds.maxY - Spacing.xs { origin.y = point.y - height - Spacing.s }
        origin.x = max(Spacing.xs, origin.x)
        origin.y = max(Spacing.xs, origin.y)
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        NSColor.windowBackgroundColor.withAlphaComponent(style.opaque ? 1 : 0.97).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        (style.highContrast ? NSColor.labelColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
        var y = rect.minY + Spacing.s
        for line in lines {
            let lineRect = CGRect(x: rect.minX + Spacing.m, y: y, width: width - 2 * Spacing.m, height: line.height)
            (line.text as NSString).draw(in: lineRect, withAttributes: line.attributes)
            y += line.height
        }
    }
}
