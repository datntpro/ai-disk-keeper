import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class DockerStatusTests: XCTestCase {
    private func status(_ s: DockerRuntimeState, disk: DockerDiskImage? = nil) -> DockerRuntimeStatus {
        DockerRuntimeStatus(definition: DockerRuntimeDefinition(id: "orbstack", displayName: "OrbStack", cliCandidates: [], socketPath: "/x"),
                            state: s, diskImage: disk)
    }

    func testModelHidesNotInstalledRuntimes() async {
        let items = [status(.notInstalled), status(.running(serverVersion: "27"))]
        let m = DockerStatusModel(detect: { items })
        m.refresh()
        for _ in 0..<50 where m.isChecking { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(m.visible.count, 1)
    }

    func testCardRendersEveryState() {
        let disk = DockerDiskImage(path: "/x", allocatedBytes: 200_000_000, logicalBytes: 8_000_000_000)
        for s in [DockerRuntimeState.running(serverVersion: "27.0"), .notRunning, .timedOut] {
            for scheme in [ColorScheme.light, .dark] {
                let m = DockerStatusModel(detect: { [] })
                _ = m
                let row = DockerRuntimeRow(status: status(s, disk: disk)).environment(\.colorScheme, scheme)
                XCTAssertNotNil(ImageRenderer(content: row.frame(width: 400)).cgImage)
            }
        }
    }

    func testRowSpokenTextHasStateAndSizes() {
        let disk = DockerDiskImage(path: "/x", allocatedBytes: 200_000_000, logicalBytes: 8_000_000_000)
        let row = DockerRuntimeRow(status: status(.running(serverVersion: "27.0"), disk: disk))
        XCTAssertTrue(row.spoken.contains("OrbStack 27.0"))
        XCTAssertTrue(row.spoken.contains("max"))
        XCTAssertTrue(DockerRuntimeRow(status: status(.notRunning)).headline.contains("isn't running"))
    }

    func testExplanationsComeFromTheProvider() {
        let item = ScanItem(url: URL(fileURLWithPath: VirtualItemPath.build(namespace: "docker", target: "t", kind: "buildcache", id: "all")!),
                            displayName: "Build cache", tool: .docker, category: .docker, sizeAllocated: 1, sizeLogical: 1, fileCount: 0,
                            lastModified: nil, tier: .safe, explanation: "en", ruleID: DockerToolCommands.Rule.buildCache)
        XCTAssertTrue(item.uiExplanation().contains("Build cache"))
    }
}
