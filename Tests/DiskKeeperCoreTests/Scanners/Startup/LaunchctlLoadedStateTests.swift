import XCTest
@testable import DiskKeeperCore

final class LaunchctlLoadedStateTests: XCTestCase {
    func testParsesRecordedOutput() {
        let states = LaunchctlLoadedState.parse(StartupFixture.launchctlSample)
        XCTAssertEqual(states["com.example.running"], .running(pid: 612))
        XCTAssertEqual(states["com.example.idle"], .loaded)
        XCTAssertEqual(states["com.adkqa.broken"], .loaded)
        XCTAssertEqual(states["application.com.example.App.1234.5678"], .running(pid: 55120))
        XCTAssertNil(states["com.example.off"])
        XCTAssertNil(states["Label"])
        XCTAssertEqual(states.count, 5)
        XCTAssertEqual(LaunchctlLoadedState.parse(""), [:])
    }

    func testRunsExactlyPrintGuiUID() async throws {
        let fx = try StartupFixture()
        let argsFile = fx.home.abs("$TMP/args")
        let exe = try fx.script("echo \"$@\" > '\(argsFile)'\ncat <<'EOF'\n\(StartupFixture.launchctlSample)\nEOF")
        let r = try await LaunchctlLoadedState(executable: exe).load(userID: 501)
        guard case .loaded(let states) = r else { return XCTFail("expected loaded") }
        XCTAssertEqual(states["com.example.running"], .running(pid: 612))
        XCTAssertEqual(try String(contentsOfFile: argsFile, encoding: .utf8), "print gui/501\n")
        XCTAssertEqual(LaunchctlLoadedState.arguments, ["print"])
    }

    func testTimeoutIsUnavailableWithinBudget() async throws {
        let fx = try StartupFixture()
        let exe = try fx.script("sleep 30")
        let started = Date()
        let r = try await LaunchctlLoadedState(
            executable: exe, runner: ProcessRunner(killGrace: .milliseconds(100)), timeout: .milliseconds(200)).load(userID: 501)
        XCTAssertEqual(r, .unavailable)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testMissingToolAndFailureAreUnavailable() async throws {
        let missing = try await LaunchctlLoadedState(executable: URL(fileURLWithPath: "/nonexistent/launchctl")).load(userID: 501)
        XCTAssertEqual(missing, .unavailable)
        let fx = try StartupFixture()
        let failing = try await LaunchctlLoadedState(executable: try fx.script("exit 3")).load(userID: 501)
        XCTAssertEqual(failing, .unavailable)
    }

    func testStartupSourcesStayReadOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let startup = sources.appendingPathComponent("DiskKeeperCore/Scanners/Startup")
        var scanned = 0
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: startup, includingPropertiesForKeys: nil))
        where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for verb in ["bootout", "bootstrap", "unload", "load", "enable", "kickstart", "kill", "remove", "submit", "disable"] {
                XCTAssertFalse(text.contains("\"\(verb)\""), "\(url.lastPathComponent) has \"\(verb)\"")
            }
        }
        XCTAssertEqual(scanned, 4)
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        where url.pathExtension == "swift" && url.lastPathComponent != "LaunchctlLoadedState.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("launchctl"), "\(url.lastPathComponent) mentions launchctl")
        }
    }
}
