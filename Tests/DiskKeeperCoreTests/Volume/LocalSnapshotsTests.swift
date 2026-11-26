import XCTest
@testable import DiskKeeperCore

final class LocalSnapshotsTests: XCTestCase {
    static let sample = """
    Snapshots for volume group containing disk /:

    com.apple.TimeMachine.2026-11-25-101010.local
    com.apple.TimeMachine.2026-11-25-111112.local

    com.apple.os.update-ABCDEF0123
    """

    private let utc = TimeZone(identifier: "UTC")!

    func testParse() {
        let s = LocalSnapshotLister.parse(Self.sample, timeZone: utc)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.map(\.kind), [.timeMachine, .timeMachine, .osUpdate])
        XCTAssertEqual(s[0].date, Date(timeIntervalSince1970: 1_795_601_410))   // 2026-11-25 10:10:10 UTC
        XCTAssertNil(s[2].date)
    }

    func testParseUnknownAndEmpty() {
        XCTAssertEqual(LocalSnapshotLister.parse("", timeZone: utc), [])
        let s = LocalSnapshotLister.parse("Snapshots for x:\nweird.name\n", timeZone: utc)
        XCTAssertEqual(s, [LocalSnapshot(name: "weird.name", date: nil, kind: .other)])
    }

    private func script(_ body: String, in tmp: TemporaryDirectory) throws -> URL {
        let url = try tmp.file("fake-tmutil.sh", contents: Data("#!/bin/sh\n\(body)\n".utf8))
        try tmp.chmod("fake-tmutil.sh", 0o755)
        return url
    }

    func testListerPassesOnlyListSubcommandAndVolume() async throws {
        let tmp = try TemporaryDirectory()
        let argsFile = tmp.path("args.txt")
        let exe = try script("echo \"$@\" > '\(argsFile)'\ncat <<'EOF'\n\(Self.sample)\nEOF", in: tmp)
        let r = try await LocalSnapshotLister(executable: exe).list(volume: "/")
        guard case .listed(let s) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(s.count, 3)
        let args = try String(contentsOfFile: argsFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(args, "listlocalsnapshots /")
    }

    func testNonZeroExit() async throws {
        let tmp = try TemporaryDirectory()
        let exe = try script("exit 3", in: tmp)
        let r = try await LocalSnapshotLister(executable: exe).list()
        XCTAssertEqual(r, .unavailable(.failed(exitStatus: 3)))
    }

    func testMissingBinary() async throws {
        let r = try await LocalSnapshotLister(executable: URL(fileURLWithPath: "/nonexistent/tmutil")).list()
        XCTAssertEqual(r, .unavailable(.toolMissing))
    }

    func testTimeout() async throws {
        let tmp = try TemporaryDirectory()
        let exe = try script("sleep 30", in: tmp)
        let start = ContinuousClock.now
        let r = try await LocalSnapshotLister(runner: ProcessRunner(killGrace: .milliseconds(100)), timeout: .milliseconds(200), executable: exe).list()
        XCTAssertEqual(r, .unavailable(.timedOut))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testCancellationRethrows() async throws {
        let tmp = try TemporaryDirectory()
        let exe = try script("sleep 30", in: tmp)
        let task = Task { try await LocalSnapshotLister(runner: ProcessRunner(killGrace: .milliseconds(100)), executable: exe).list() }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
    }

    func testBadVolumeNeverSpawns() async throws {
        let tmp = try TemporaryDirectory()
        let marker = tmp.path("ran")
        let exe = try script("touch '\(marker)'", in: tmp)
        let lister = LocalSnapshotLister(executable: exe)
        for bad in ["../x", "relative", "/a/../b"] {
            let r = try await lister.list(volume: bad)
            XCTAssertEqual(r, .unavailable(.badVolume), bad)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }
}
