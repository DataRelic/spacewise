import Foundation
import SpacewiseCore

extension ScanResult {
    /// The path a person recognizes: the unified drive shows Data-volume paths rooted at /; folder scans show real paths.
    public func displayPath(for id: Int) -> String? {
        namespace.unified ? logicalPathString(for: id) : url(for: id)?.path
    }

    /// Where an item can be revealed or copied. A folder merged from both volumes has no single physical location, so
    /// its logical path is the real one.
    public func revealURL(for id: Int) -> URL? {
        if namespace.isMerged(id) { return displayPath(for: id).map { URL(fileURLWithPath: $0) } }
        return url(for: id)
    }
}
