import XCTest
@testable import DiskKeeperCore

final class ClaudeProjectResolverTests: XCTestCase {
    private var tmp: TemporaryDirectory!
    private var dir: String { tmp.path("p") }

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        try tmp.dir("p")
    }

    override func tearDown() {
        if tmp != nil {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                chmod(dir + "/" + f, 0o644)
            }
        }
        tmp = nil
    }

    private func transcript(_ name: String, _ text: String, modified: Date = Date()) throws {
        try tmp.file("p/\(name)", contents: Data(text.utf8))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: dir + "/" + name)
    }

    private func resolve(_ encoded: String = "-Users-me-src-my-app") -> ProjectRef {
        var r = ClaudeProjectResolver()
        return r.project(forProjectDir: dir, encodedName: encoded)
    }

    func testCwdFromFirstLineWithCwd() throws {
        try transcript("a.jsonl", #"{"type":"summary"}"# + "\n" + #"{"cwd":"/Users/me/src/app","x":1}"# + "\n" + #"{"cwd":"/other"}"# + "\n")
        let ref = resolve()
        XCTAssertEqual(ref.id, "/Users/me/src/app")
        XCTAssertEqual(ref.displayName, "app")
    }

    func testNewestTranscriptIsUsed() throws {
        try transcript("old.jsonl", #"{"cwd":"/old/proj"}"# + "\n", modified: Date(timeIntervalSinceNow: -1000))
        try transcript("new.jsonl", #"{"cwd":"/new/proj"}"# + "\n", modified: Date(timeIntervalSinceNow: -10))
        XCTAssertEqual(resolve().id, "/new/proj")
    }

    func testOnly64KiBRead() throws {
        let pad = String(repeating: "x", count: 70_000)
        try transcript("a.jsonl", #"{"pad":"\#(pad)"}"# + "\n" + #"{"cwd":"/too/late"}"# + "\n")
        XCTAssertEqual(resolve().id, "name:-Users-me-src-my-app")
        // Within the window it is found.
        try transcript("a.jsonl", #"{"pad":"\#(String(repeating: "x", count: 60_000))"}"# + "\n" + #"{"cwd":"/in/time"}"# + "\n")
        XCTAssertEqual(resolve().id, "/in/time")
    }

    func testRelativeOrDotDotCwdRejected() throws {
        try transcript("a.jsonl", #"{"cwd":"relative/dir"}"# + "\n" + #"{"cwd":"/a/../b"}"# + "\n" + #"{"cwd":5}"# + "\n")
        XCTAssertEqual(resolve().id, "name:-Users-me-src-my-app")
    }

    func testFallbackDisplayName() {
        let ref = resolve("-Users-me-src-my-app")   // no transcripts at all
        XCTAssertEqual(ref.displayName, "app")
        XCTAssertEqual(ref.id, "name:-Users-me-src-my-app")
        XCTAssertEqual(ClaudeProjectResolver.fallback(encodedName: "---").displayName, "---")
    }

    func testUnreadableFileFallsBackSilently() throws {
        try transcript("a.jsonl", #"{"cwd":"/a/b"}"# + "\n")
        XCTAssertEqual(chmod(dir + "/a.jsonl", 0), 0)
        XCTAssertEqual(resolve().id, "name:-Users-me-src-my-app")
    }

    func testResultIsCachedPerProjectDir() throws {
        try transcript("a.jsonl", #"{"cwd":"/a/b"}"# + "\n")
        var r = ClaudeProjectResolver()
        XCTAssertEqual(r.project(forProjectDir: dir, encodedName: "x").id, "/a/b")
        try FileManager.default.removeItem(atPath: dir + "/a.jsonl")
        XCTAssertEqual(r.project(forProjectDir: dir, encodedName: "x").id, "/a/b")
    }
}
