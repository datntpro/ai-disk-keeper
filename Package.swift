// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AIDiskKeeper",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AIDiskKeeper", targets: ["AIDiskKeeper"]),
        .library(name: "DiskKeeperCore", targets: ["DiskKeeperCore"]),
        // Machine status for coding agents (`adk status`); shipped at Contents/MacOS/adk. Reads one file, no app launch.
        .executable(name: "adk", targets: ["adk"]),
    ],
    targets: [
        // Scan engine, scanner rules, safety policy, cleanup engine. No UI code.
        .target(
            name: "DiskKeeperCore",
            resources: [.copy("Resources/Rules")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        // SwiftUI views and view models. A library so view models are testable without importing an executable.
        .target(
            name: "AIDiskKeeperUI",
            dependencies: ["DiskKeeperCore"],
            resources: [.process("Resources/Localizable.xcstrings")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        // SwiftUI app entry (window + menu bar). Thin layer over AIDiskKeeperUI.
        .executableTarget(
            name: "AIDiskKeeper",
            dependencies: ["DiskKeeperCore", "AIDiskKeeperUI"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "adk",
            dependencies: ["DiskKeeperCore"],
            path: "Sources/adk",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        // Developer-only read-only scan CLI (`swift run adk-scan`). Not a product; never shipped in the app.
        .executableTarget(
            name: "adk-scan",
            dependencies: ["DiskKeeperCore"],
            path: "Sources/adk-scan",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "DiskKeeperCoreTests",
            dependencies: ["DiskKeeperCore"]
        ),
        .testTarget(
            name: "AIDiskKeeperUITests",
            dependencies: ["AIDiskKeeperUI", "DiskKeeperCore"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
