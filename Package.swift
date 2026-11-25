// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AIDiskKeeper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AIDiskKeeper", targets: ["AIDiskKeeper"]),
        .library(name: "DiskKeeperCore", targets: ["DiskKeeperCore"]),
    ],
    targets: [
        // Scan engine, scanner rules, safety policy, cleanup engine. No UI code.
        .target(
            name: "DiskKeeperCore",
            resources: [.copy("Resources/Rules")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        // SwiftUI app (window + menu bar). Thin layer over DiskKeeperCore.
        .executableTarget(
            name: "AIDiskKeeper",
            dependencies: ["DiskKeeperCore"],
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
    ]
)
