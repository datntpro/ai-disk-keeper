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
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        // SwiftUI app (window + menu bar). Thin layer over DiskKeeperCore.
        .executableTarget(
            name: "AIDiskKeeper",
            dependencies: ["DiskKeeperCore"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "DiskKeeperCoreTests",
            dependencies: ["DiskKeeperCore"]
        ),
    ]
)
