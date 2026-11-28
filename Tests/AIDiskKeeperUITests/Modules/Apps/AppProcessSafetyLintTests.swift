import Foundation
import XCTest

/// Grep-style guard: only `AppProcessController.swift` may signal another process, and no test may build the live controller.
final class AppProcessSafetyLintTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func swiftFiles(_ sub: String) -> [URL] {
        let base = root.appendingPathComponent(sub)
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func testOnlyTheControllerSignalsProcesses() throws {
        let forbidden = try NSRegularExpression(pattern: #"forceTerminate\(|\.terminate\(\)|\bkill\(|\bkillpg\(|NSRunningApplication\(processIdentifier:"#)
        let files = swiftFiles("Sources").filter {
            !$0.path.hasSuffix("Modules/Apps/AppProcessController.swift") && !$0.path.hasSuffix("Git/ProcessRunner.swift") // ProcessRunner times out its own child
                && !$0.path.hasSuffix("Process/ProcessControl.swift") // H5: SIGSTOP/SIGCONT only, pinned by ProcessControlSourceLintTests
        }
        XCTAssertFalse(files.isEmpty)
        for f in files {
            let text = try String(contentsOf: f)
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNil(forbidden.firstMatch(in: text, range: range), "\(f.lastPathComponent) may not signal or activate other processes")
        }
    }

    func testNoTestBuildsTheLiveController() throws {
        let needle = "WorkspaceAppProcessController" + "("
        for f in swiftFiles("Tests") where !f.path.hasSuffix("AppProcessSafetyLintTests.swift") {
            XCTAssertFalse(try String(contentsOf: f).contains(needle), "\(f.lastPathComponent) must use FakeAppProcessController")
        }
    }
}
