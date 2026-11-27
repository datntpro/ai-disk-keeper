import XCTest
@testable import DiskKeeperCore

final class HostStatusCLITests: XCTestCase {
    private var tmp: TemporaryDirectory!
    private var url: URL!
    private let now = HostStatusFixtures.date.addingTimeInterval(10)
    override func setUpWithError() throws { tmp = try TemporaryDirectory(); url = tmp.url.appendingPathComponent("status.json") }
    override func tearDown() { tmp = nil }

    private func put(_ s: HostStatus) throws { try HostStatusFixtures.data(s).write(to: url) }
    private func run(_ args: [String]) -> HostStatusCLI.Output { HostStatusCLI.run(args: args, statusURL: url, now: now) }

    func testLevelsMapToExitCodes() throws {
        for (level, code) in [(HostStatusLevel.ok, Int32(0)), (.warn, 10), (.critical, 20)] {
            try put(HostStatusFixtures.status(level: level))
            XCTAssertEqual(run(["status"]).exitCode, code)
        }
    }

    func testTextShowsReasonsAndDiskLine() throws {
        try put(HostStatusFixtures.status(level: .warn))
        let out = run(["status"])
        XCTAssertTrue(out.stdout.contains("level: warn"))
        XCTAssertTrue(out.stdout.contains("- Free space 13% (< 15%)"))
        XCTAssertTrue(out.stdout.contains("disk: 13.0% free"))
        XCTAssertEqual(out.stderr, "")
    }

    func testStaleMissingAndNotRunningAreExit3() throws {
        XCTAssertEqual(run(["status"]).exitCode, 3, "missing")
        try put(HostStatusFixtures.status(level: .ok, at: HostStatusFixtures.date.addingTimeInterval(-200)))
        XCTAssertEqual(run(["status"]).exitCode, 3, "older than 120 s")
        XCTAssertEqual(run(["status", "--max-age", "600"]).exitCode, 0)
        try put(HostStatusFixtures.status(level: .critical, running: false, at: HostStatusFixtures.date))
        XCTAssertEqual(run(["status"]).exitCode, 3, "quit: running false")
    }

    func testSchemaMismatchAndGarbageAreExit4() throws {
        try put(HostStatusFixtures.status(schemaVersion: 2))
        XCTAssertEqual(run(["status"]).exitCode, 4)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(run(["status"]).exitCode, 4)
        try Data(#"{"schemaVersion":1}"#.utf8).write(to: url)
        XCTAssertEqual(run(["status"]).exitCode, 4, "right version, wrong shape")
    }

    func testJSONIsPassedThroughAndQuietPrintsNothing() throws {
        try put(HostStatusFixtures.status(level: .warn))
        let json = run(["status", "--json"])
        XCTAssertEqual(json.exitCode, 10)
        XCTAssertEqual(json.stdout, String(decoding: try Data(contentsOf: url), as: UTF8.self) + "\n")
        let quiet = run(["status", "--quiet"])
        XCTAssertEqual(quiet, .init(stdout: "", stderr: "", exitCode: 10))
        XCTAssertEqual(run(["status", "--quiet", "--max-age", "1"]).stderr, "", "quiet also silences the stale message")
    }

    func testWorktreeFilter() throws {
        try put(HostStatusFixtures.status(level: .ok))
        let hit = run(["status", "--worktree", "/Users/u/wt/a/sub/dir"])
        XCTAssertTrue(hit.stdout.contains("worktree /Users/u/wt/a: writes 2.0 MB/s, 3 process(es), agents: claude"))
        XCTAssertTrue(hit.stdout.contains("claude (pid 1)"))
        XCTAssertFalse(hit.stdout.contains("mdworker"))
        XCTAssertTrue(run(["status", "--worktree", "/Users/u/wt/other"]).stdout.contains("no recorded disk activity"))
        XCTAssertEqual(run(["status", "--worktree", "/Users/u/wt/a"]).exitCode, 0)
    }

    func testBadArgumentsAreExit2() {
        for args in [[], ["bogus"], ["status", "--nope"], ["status", "--max-age"], ["status", "--max-age", "x"], ["status", "--worktree"]] {
            XCTAssertEqual(run(args).exitCode, 2, "\(args)")
        }
        XCTAssertEqual(run(["--help"]).exitCode, 0)
        XCTAssertTrue(run(["status", "--nope"]).stderr.contains("usage:"))
    }
}
