// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Spacewise",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SpacewiseCore", targets: ["SpacewiseCore"]),
        .executable(name: "Spacewise", targets: ["SpacewiseApp"]),
    ],
    targets: [
        .target(name: "SpacewiseCore"),
        // The app's AppKit-free logic (what is enabled, where navigation goes, what each panel shows), so it can be tested.
        .target(name: "SpacewiseAppModel", dependencies: ["SpacewiseCore"]),
        .executableTarget(name: "SpacewiseApp", dependencies: ["SpacewiseCore", "SpacewiseAppModel"]),
        // Development helper the scripts use to find and quit the installed app. Not installed or shipped.
        .executableTarget(name: "SpacewiseControl"),
        // Made-up scan results shared by the test targets. Not part of any product.
        .target(name: "SpacewiseFixtures", dependencies: ["SpacewiseCore"], path: "Tests/SpacewiseFixtures"),
        .testTarget(name: "SpacewiseCoreTests", dependencies: ["SpacewiseCore", "SpacewiseFixtures"]),
        .testTarget(
            name: "SpacewiseAppTests",
            dependencies: ["SpacewiseApp", "SpacewiseAppModel", "SpacewiseCore", "SpacewiseFixtures"]),
        .testTarget(
            name: "SpacewiseAppModelTests", dependencies: ["SpacewiseAppModel", "SpacewiseCore", "SpacewiseFixtures"]),
    ]
)
