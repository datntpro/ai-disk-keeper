import XCTest

/// The monitor reads public counters only: no child process, private framework, privileged helper, per-view timer
/// or cleanup path anywhere in its sources.
final class SystemMonitorLintTests: XCTestCase {
    private let banned = [
        "Process(", "NSTask", "posix_spawn", "dlopen", "dlsym", "NSAppleScript", "/usr/bin/", "/usr/sbin/", "powermetrics",
        "IOReport", "SMC", "AuthorizationCreate", "SMJobBless", "Timer.publish", "TimelineView", "proc_pidpath",
        "StorageModel", ".refresh(", "Cleanup", "kill(", "terminate",
    ]

    private func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testNoBannedSymbols() throws {
        var checked = 0
        for dir in ["Sources/DiskKeeperCore/SystemMonitor", "Sources/AIDiskKeeperUI/SystemMonitor"] {
            let url = root().appendingPathComponent(dir)
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
            XCTAssertGreaterThanOrEqual(files.count, 8, dir)
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                for word in banned where text.contains(word) { XCTFail("\(file.lastPathComponent) contains \(word)") }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 15)
    }

    func testOnlyOneMenuBarExtra() throws {
        let app = try String(contentsOf: root().appendingPathComponent("Sources/AIDiskKeeper/AIDiskKeeperApp.swift"), encoding: .utf8)
        XCTAssertEqual(app.components(separatedBy: "MenuBarExtra(").count - 1, 1)
        XCTAssertFalse(app.contains("NSStatusItem"))
    }
}
