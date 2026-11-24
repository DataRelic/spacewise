import Foundation

/// The running build, as the bundle records it.
enum BuildInfo {
    /// The bundle's build version, or "unbundled" when run straight from the build directory.
    static let identity = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unbundled"
}
