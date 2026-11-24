import AppKit

/// A plain container whose origin is the top left, so a scroll view's document starts at its top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
