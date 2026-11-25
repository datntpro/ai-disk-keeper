import XCTest
@testable import DiskKeeperCore
import protocol DiskKeeperCore.Scanner

final class ScanEngineReadOnlyTests: XCTestCase {
    private var fixture: FixtureHome!
    private var rulesDir: TemporaryDirectory!
    private var restore: [String] = []

    override func setUpWithError() throws {
        fixture = try FixtureHome()
        rulesDir = try TemporaryDirectory()
    }

    override func tearDown() {
        for p in restore { chmod(p, 0o755) }
        restore = []
        fixture = nil
        rulesDir = nil
    }

    func testScanModifiesNothing() async throws {
        for i in 0..<100 { try fixture.file(".t/cache/sub\(i % 10)/f\(i)", bytes: 50 + i) }
        for i in 0..<100 { try fixture.file(".t/work/proj\(i)/data", bytes: 10) }
        for i in 0..<30 { try fixture.file("code/repo\(i)/.git/HEAD"); try fixture.dir("code/repo\(i)/.aider.tags.cache.v4") }
        try fixture.file(".t/cache/real", bytes: 4096)
        try fixture.symlink(".t/cache/loop", to: fixture.abs(".t/cache"))
        try FileManager.default.linkItem(atPath: fixture.abs(".t/cache/real"), toPath: fixture.abs(".t/work/hardlink"))
        try fixture.dir(".t/cache/locked")
        try fixture.file(".t/cache/locked/secret", bytes: 7)
        let locked = fixture.abs(".t/cache/locked")
        restore.append(locked)

        try rulesDir.file("t.json", contents: Data(RuleFixtures.file(tool: "t", rules: [
            RuleFixtures.rule(id: "t.cache", paths: #"["~/.t/cache"]"#),
            RuleFixtures.rule(id: "t.work", paths: #"["~/.t/work"]"#, match: #"{"kind":"children"}"#),
            RuleFixtures.rule(id: "t.aider", paths: #"["~/code"]"#,
                              match: #"{"kind":"find","name":".aider.tags.cache.v*","marker":".git","maxDepth":3}"#),
        ]).utf8))
        let before = try fixture.snapshot()   // readable: includes locked/secret
        chmod(locked, 0o000)                   // the scan sees it unreadable
        XCTAssertGreaterThan(before.count, 300)

        let engine = try ScanEngine.makeDefault(environment: fixture.env, bundledRulesDirectory: rulesDir.url,
                                                maxConcurrentSizing: 4)
        let events = await EngineKit.collect(try await engine.scan())
        let result = try XCTUnwrap(EngineKit.terminal(events)?.result)
        XCTAssertGreaterThan(result.items.count, 30)

        chmod(fixture.abs(".t/cache/locked"), 0o755)   // the snapshot must be able to read it back
        let after = try fixture.snapshot()
        XCTAssertEqual(before.keys.sorted(), after.keys.sorted(), "no entries created or removed")
        for (path, entry) in before { XCTAssertEqual(entry, after[path], path) }
    }
}
