import CoreGraphics

/// The main window's sizes, and how its first frame is chosen.
public enum WindowLayout {
    /// The name AppKit saves the window frame under.
    public static let autosaveName = "SpacewiseMain"
    /// The defaults key AppKit stores that frame under.
    public static let savedFrameKey = "NSWindow Frame " + autosaveName
    /// Content size of a first launch.
    public static let defaultContentSize = CGSize(width: 1260, height: 800)
    /// The smallest window.
    public static let minimumSize = CGSize(width: 900, height: 560)
    /// The content view's own floor, below the window minimum.
    public static let minimumContentSize = CGSize(width: 840, height: 460)
    /// Content shorter than this trades secondary figures for map height.
    public static let compactHeight: CGFloat = 640
    /// Content at least this wide shows the inspector unless the person has toggled it.
    public static let inspectorWidth: CGFloat = 1100

    public enum InitialFrame: Equatable {
        /// Put back the frame the person left (installing the content and toolbar resizes the window first).
        case restoreSaved(name: String)
        /// First launch: the default content size, centred.
        case centered(contentSize: CGSize)
    }

    /// `savedFrame` is whatever the defaults hold under `savedFrameKey`. Only a value that reads as a frame with a
    /// positive size is restored; anything else (missing, damaged, another type) starts at the default size, centred.
    public static func initialFrame(savedFrame: Any?) -> InitialFrame {
        savedFrameRect(savedFrame) != nil
            ? .restoreSaved(name: autosaveName) : .centered(contentSize: defaultContentSize)
    }

    /// The window frame in AppKit's saved form, "x y width height" followed by the screen's frame, or nil when the value
    /// is not one.
    public static func savedFrameRect(_ value: Any?) -> CGRect? {
        guard let text = value as? String else { return nil }
        let numbers = text.split(separator: " ").map { Double($0) }
        guard numbers.count >= 4, numbers.prefix(4).allSatisfy({ $0?.isFinite == true }) else { return nil }
        // Checked before building the rectangle: CGRect's width and height read negative sizes as positive.
        guard numbers[2]! > 0, numbers[3]! > 0 else { return nil }
        return CGRect(x: numbers[0]!, y: numbers[1]!, width: numbers[2]!, height: numbers[3]!)
    }
}
