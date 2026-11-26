import XCTest
@testable import DiskKeeperCore

final class CareHistoryStoreTests: XCTestCase {
    private func store() throws -> (CareHistoryStore, TemporaryDirectory) {
        let dir = try TemporaryDirectory()
        return (CareHistoryStore(fileURL: dir.url.appendingPathComponent("AIDiskKeeper/care-history.json")), dir)
    }

    private func scan(_ store: CareHistoryStore, claudeBytes: Int64, fingerprint: String = "fp",
                      at date: Date = Date()) async throws -> CareReport {
        let events = try await CareKit.run([
            FakeStage.spec(.rules, modules: [.aiTools], items: [
                CareKit.item("/f/claude", size: claudeBytes, tool: "claude-code"),
                CareKit.item("/f/codex", size: 1_000, tool: "codex"),
            ]),
        ], history: store, fingerprint: fingerprint, clock: { date })
        return try XCTUnwrap(CareKit.report(events))
    }

    func testFirstScanHasNoGrowthAndSecondShowsDelta() async throws {
        let (h, _) = try store()
        let first = try await scan(h, claudeBytes: 1_000_000_000, at: Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(first.growth)
        let second = try await scan(h, claudeBytes: 4_200_000_000, at: Date(timeIntervalSince1970: 2_000))
        let g = try XCTUnwrap(second.growth)
        XCTAssertEqual(g.aiToolsDelta, 3_200_000_000)
        XCTAssertEqual(g.perTool["claude-code"], 3_200_000_000)
        XCTAssertEqual(g.perTool["codex"], 0)
        XCTAssertEqual(g.since, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(h.load().count, 2)
    }

    func testDifferentFingerprintHasNoGrowth() async throws {
        let (h, _) = try store()
        _ = try await scan(h, claudeBytes: 10, fingerprint: "a")
        let other = try await scan(h, claudeBytes: 99, fingerprint: "b")
        XCTAssertNil(other.growth)
        let back = try await scan(h, claudeBytes: 50, fingerprint: "a")
        XCTAssertEqual(back.growth?.aiToolsDelta, 40)
    }

    func testCancelledScanAppendsNothing() async throws {
        let (h, _) = try store()
        let counter = CareCallCounter()
        let c = CareScanCoordinator(stages: [FakeStage.spec(.rules, items: [CareKit.item("/f/a")], awaitCancel: true, counter: counter)],
                                    history: h, scopeFingerprint: "fp")
        let stream = try await c.scan()
        let collector = Task { await CareKit.collect(stream) }
        while counter.count(.rules) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await c.cancel()
        let events = await collector.value
        XCTAssertNil(CareKit.report(events)?.growth)
        XCTAssertTrue(h.load().isEmpty)
    }

    func testFailedRulesStageAppendsNothing() async throws {
        let (h, _) = try store()
        _ = try await CareKit.run([FakeStage.spec(.rules, throwAfter: 0)], history: h)
        XCTAssertTrue(h.load().isEmpty)
    }

    func testCorruptFileIsTreatedAsEmptyThenOverwritten() async throws {
        let (h, _) = try store()
        try FileManager.default.createDirectory(at: h.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json {".utf8).write(to: h.fileURL)
        XCTAssertEqual(h.load(), [])
        let r = try await scan(h, claudeBytes: 5)
        XCTAssertNil(r.growth)
        XCTAssertEqual(h.load().count, 1)
    }

    func testKeepsOnlyTheLast20() throws {
        let (h, _) = try store()
        for i in 0..<25 {
            try h.append(CareSnapshot(finishedAt: Date(timeIntervalSince1970: Double(i)), scopeFingerprint: "x",
                                      perTool: [:], perModule: [:]))
        }
        let all = h.load()
        XCTAssertEqual(all.count, 20)
        XCTAssertEqual(all.first?.finishedAt, Date(timeIntervalSince1970: 5))
    }

    func testFilePermissionsAndNoPathsPersisted() async throws {
        let (h, _) = try store()
        _ = try await scan(h, claudeBytes: 5)
        let file = try FileManager.default.attributesOfItem(atPath: h.fileURL.path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: h.fileURL.deletingLastPathComponent().path)
        XCTAssertEqual((dir[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let text = try String(contentsOf: h.fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("/f/claude"), "totals only, no paths")
        XCTAssertTrue(text.contains("claude-code"))
    }

    func testDefaultFileURL() {
        let env = PathEnvironment(home: "/Users/x", temporaryDirectory: "/tmp", variables: [:])
        XCTAssertEqual(CareHistoryStore.defaultFileURL(environment: env).path,
                       "/Users/x/Library/Application Support/AIDiskKeeper/care-history.json")
    }

    func testKeepsNewerSchemaEntriesAndTightensExistingDirectory() throws {
        let (h, _) = try store()
        let dir = h.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let newer = #"[{"schemaVersion":2,"finishedAt":"2026-01-01T00:00:00.000Z","scopeFingerprint":"x","perTool":{},"perModule":{}}]"#
        try Data(newer.utf8).write(to: h.fileURL)
        try h.append(CareSnapshot(finishedAt: Date(), scopeFingerprint: "x", perTool: [:], perModule: [:]))
        XCTAssertEqual(h.load().map(\.schemaVersion), [2, 1])
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}
