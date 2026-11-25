import XCTest

@testable import DiskKeeperCore

final class ProcessRunnerTests: XCTestCase {
    private let sh = URL(fileURLWithPath: "/bin/sh")
    private let tmp = URL(fileURLWithPath: "/tmp")

    private func run(
        _ script: String, runner: ProcessRunner = ProcessRunner(), timeout: Duration = .seconds(10)
    ) async throws -> ProcessResult {
        try await runner.run(
            executable: sh, arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: tmp, timeout: timeout)
    }

    private func pgrep(_ pattern: String) throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", pattern]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func testCapturesStdoutStderrAndExitCode() async throws {
        let r = try await run("echo out; echo err >&2; exit 3")
        XCTAssertEqual(r.stdoutString, "out\n")
        XCTAssertEqual(r.stderrString, "err\n")
        XCTAssertEqual(r.exitStatus, 3)
        XCTAssertFalse(r.terminatedBySignal)
    }

    func testEnvironmentIsExactlyAsGiven() async throws {
        let r = try await ProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [], environment: ["A": "1"],
            currentDirectory: tmp, timeout: .seconds(5))
        XCTAssertEqual(r.stdoutString.split(separator: "\n").map(String.init), ["A=1"])
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        let start = ContinuousClock.now
        let r = try await run("yes | head -c 50000000", runner: ProcessRunner(maxOutputBytes: 1 << 20))
        XCTAssertTrue(r.stdoutTruncated)
        XCTAssertEqual(r.stdout.count, 1 << 20)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(10))
    }

    func testTimeoutKillsProcess() async throws {
        let marker = "30.7\(Int.random(in: 100_000...999_999))"
        let start = ContinuousClock.now
        do {
            _ = try await run("sleep \(marker); : done", timeout: .milliseconds(300))
            XCTFail("expected timeout")
        } catch let e as ProcessRunnerError {
            guard case .timedOut = e else { return XCTFail("\(e)") }
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(try pgrep("sleep \(marker)"))
    }

    func testSIGTERMIgnoringChildIsKilled() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await run(
                "trap '' TERM; sleep 30", runner: ProcessRunner(killGrace: .milliseconds(500)),
                timeout: .milliseconds(300))
            XCTFail("expected timeout")
        } catch is ProcessRunnerError {}
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(300) + .milliseconds(500) + .seconds(1))
    }

    func testCancellationTerminates() async throws {
        let task = Task { try await self.run("sleep 30") }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(1500))
    }

    func testLaunchFailure() async {
        do {
            _ = try await ProcessRunner().run(
                executable: URL(fileURLWithPath: "/nonexistent/bin"), arguments: [], environment: [:],
                currentDirectory: tmp, timeout: .seconds(1))
            XCTFail("expected failure")
        } catch let e as ProcessRunnerError {
            guard case .launchFailed = e else { return XCTFail("\(e)") }
        } catch { XCTFail("\(error)") }
    }

    func testStdinIsDevNull() async throws {
        let r = try await ProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:],
            currentDirectory: tmp, timeout: .seconds(5))
        XCTAssertTrue(r.stdout.isEmpty)
        XCTAssertEqual(r.exitStatus, 0)
    }
}
