import XCTest
@testable import DiskKeeperCore

/// Runs temp-dir `#!/bin/sh` fakes only. Never a real tool.
final class ToolCommandRunnerTests: XCTestCase {
    private var fx: TemporaryDirectory!
    override func setUpWithError() throws { fx = try TemporaryDirectory() }
    override func tearDown() { fx = nil }

    private func tool(_ body: String) throws -> URL { URL(fileURLWithPath: try ToolFixtures.writeTool(in: fx, body: body)) }

    func testEnvironmentIsExactlyWhatWasPassedAndArgvIsLiteral() async throws {
        let log = fx.path("log")
        let exe = try tool("""
        printf '%s\\0' "$0" "$@" > '\(log).argv'
        env | sort > '\(log).env'
        """)
        let injected = "; touch \(fx.path("pwned"))"
        let env = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": "/h", "ADK_X": "1"]
        let r = try await ToolCommandRunner().run(executable: exe, arguments: ["a b", injected], environment: env,
                                                  timeout: .seconds(5), maxStdout: 1024)
        XCTAssertEqual(r.exitStatus, 0)
        let argv = try String(contentsOfFile: log + ".argv").split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        XCTAssertEqual(argv, [exe.path, "a b", injected])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.path("pwned")))
        let keys = try String(contentsOfFile: log + ".env").split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
        // /bin/sh adds PWD, SHLVL, _ and OLDPWD itself; nothing from the app's environment may appear.
        XCTAssertEqual(Set(keys).subtracting(["PWD", "SHLVL", "_", "OLDPWD", "__CF_USER_TEXT_ENCODING"]), Set(env.keys))
    }

    func testWorkingDirectoryIsRoot() async throws {
        let exe = try tool("pwd")
        let r = try await ToolCommandRunner().run(executable: exe, arguments: [], environment: [:], timeout: .seconds(5), maxStdout: 1024)
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "/")
    }

    func testExitStatusAndStderrTail() async throws {
        let exe = try tool("echo boom >&2; exit 3")
        let r = try await ToolCommandRunner().run(executable: exe, arguments: [], environment: [:], timeout: .seconds(5), maxStdout: 1024)
        XCTAssertEqual(r.exitStatus, 3); XCTAssertEqual(r.stderrTail, "boom\n"); XCTAssertFalse(r.timedOut)
    }

    func testTimeoutKillsTheProcessGroup() async throws {
        let pidFile = fx.path("child.pid")
        let exe = try tool("sleep 30 &\necho $! > '\(pidFile)'\nwait")
        let started = ContinuousClock.now
        let r = try await ToolCommandRunner(killGrace: .milliseconds(200)).run(
            executable: exe, arguments: [], environment: [:], timeout: .milliseconds(500), maxStdout: 1024)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotEqual(kill(pid, 0), 0, "the sleeping child must be gone")
    }

    func testStdoutCapHolds() async throws {
        let exe = try tool("yes | head -c 200000")
        let r = try await ToolCommandRunner().run(executable: exe, arguments: [], environment: [:], timeout: .seconds(5), maxStdout: 1000)
        XCTAssertLessThanOrEqual(r.stdout.count, 1000)
    }

    func testCancellationTerminates() async throws {
        let exe = try tool("sleep 30")
        let task = Task { try await ToolCommandRunner(killGrace: .milliseconds(200)).run(
            executable: exe, arguments: [], environment: [:], timeout: .seconds(60), maxStdout: 10) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do { _ = try await task.value; XCTFail("did not throw") } catch is CancellationError {}
    }

    func testStderrTailKeepsLastBytesAndIsUTF8Safe() {
        let big = Data(repeating: 0x41, count: 70_000) + Data("é".utf8) + Data("end".utf8)
        let tail = ToolCommandRunner.tail(big)
        XCTAssertTrue(tail.hasSuffix("éend"))
        XCTAssertLessThanOrEqual(tail.utf8.count, 64 << 10)
        XCTAssertFalse(tail.contains("\u{FFFD}"))
    }

    func testBaseEnvironment() {
        XCTAssertEqual(ToolCommandRunner.baseEnvironment(home: "/h"),
                       ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": "/h"])
    }
}
