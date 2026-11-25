import XCTest
@testable import DiskKeeperCore

private func assertSendable<T: Sendable>(_: T.Type) {}

final class ScanItemTests: XCTestCase {
    func testRoundTripFullyPopulated() throws {
        let item = ModelFixtures.fullItem()
        XCTAssertEqual(item.flags.count, 6)
        XCTAssertEqual(try roundTrip(item), item)
    }

    func testRoundTripMinimalOmitsOptionalKeys() throws {
        let item = ModelFixtures.item()
        var copy = item
        copy.lastModified = nil
        let data = try DiskKeeperJSON.makeEncoder().encode(copy)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(obj["project"])
        XCTAssertNil(obj["lastModified"])
        XCTAssertNil(obj["requiresAppQuit"])
        XCTAssertEqual(obj["flags"] as? [String], [])
        XCTAssertEqual(try roundTrip(copy), copy)
    }

    private let pinned = """
    {"category":"aiToolData","cleanup":{"kind":"trash"},"displayName":"app","explanation":"why",
     "fileCount":12,"flags":["sizeIncomplete"],
     "id":"claude-code.projects|/Users/me/.claude/projects/-Users-me-app",
     "lastModified":"2026-11-01T10:00:00.000Z",
     "path":"/Users/me/.claude/projects/-Users-me-app",
     "project":{"displayName":"app","id":"/Users/me/app"},
     "requiresAppQuit":"com.anthropic.claudefordesktop","ruleID":"claude-code.projects",
     "sizeAllocated":4096,"sizeLogical":1200,"tier":"review","tool":"claude-code"}
    """

    func testDecodesPinnedJSONFixture() throws {
        let i = try decodeJSON(ScanItem.self, pinned)
        XCTAssertEqual(i.id, "claude-code.projects|/Users/me/.claude/projects/-Users-me-app")
        XCTAssertEqual(i.path, "/Users/me/.claude/projects/-Users-me-app")
        XCTAssertEqual(i.displayName, "app")
        XCTAssertEqual(i.tool, .claudeCode)
        XCTAssertEqual(i.category, .aiToolData)
        XCTAssertEqual(i.project, ProjectRef(id: "/Users/me/app", displayName: "app"))
        XCTAssertEqual(i.project?.displayName, "app")
        XCTAssertEqual(i.sizeAllocated, 4096)
        XCTAssertEqual(i.sizeLogical, 1200)
        XCTAssertEqual(i.fileCount, 12)
        XCTAssertEqual(i.lastModified?.timeIntervalSince1970, 1_793_527_200)
        XCTAssertEqual(i.tier, .review)
        XCTAssertEqual(i.explanation, "why")
        XCTAssertEqual(i.ruleID, "claude-code.projects")
        XCTAssertEqual(i.cleanupMethod, .trash)
        XCTAssertEqual(i.requiresAppQuit, "com.anthropic.claudefordesktop")
        XCTAssertEqual(i.flags, [.sizeIncomplete])
    }

    func testURLIsStandardized() {
        let a = ModelFixtures.item(path: "/Users/test/a/../b/")
        let b = ModelFixtures.item(path: "/Users/test/b")
        XCTAssertEqual(a.path, "/Users/test/b")
        XCTAssertEqual(a.url, b.url)
        XCTAssertEqual(a, b)
    }

    func testSymlinksAreNotResolved() {
        XCTAssertEqual(ModelFixtures.item(path: "/private/var/x").path, "/private/var/x")
        XCTAssertEqual(ModelFixtures.item(path: "/var/x").path, "/var/x")
    }

    func testDefaultIDIsRuleAndPath() {
        XCTAssertEqual(ModelFixtures.item(path: "/x/y", ruleID: "r").id, "r|/x/y")
    }

    func testExplicitIDIsKept() {
        let i = ScanItem(id: "custom", url: URL(fileURLWithPath: "/x"), displayName: "n", tool: .git,
                         category: .worktree, sizeAllocated: 0, sizeLogical: 0, fileCount: 0,
                         lastModified: nil, tier: .keep, explanation: "", ruleID: "r")
        XCTAssertEqual(i.id, "custom")
    }

    func testDecodingRelativePathThrows() {
        let json = pinned.replacingOccurrences(of: "\"path\":\"/Users", with: "\"path\":\"Users")
        XCTAssertThrowsError(try decodeJSON(ScanItem.self, json))
    }

    func testDecodingNegativeSizeThrows() {
        for (from, to) in [("\"sizeAllocated\":4096", "\"sizeAllocated\":-1"),
                           ("\"sizeLogical\":1200", "\"sizeLogical\":-1"),
                           ("\"fileCount\":12", "\"fileCount\":-1")] {
            XCTAssertThrowsError(try decodeJSON(ScanItem.self, pinned.replacingOccurrences(of: from, with: to)), to)
        }
    }

    func testDecodingMissingIDThrows() {
        let json = pinned.replacingOccurrences(
            of: "\"id\":\"claude-code.projects|/Users/me/.claude/projects/-Users-me-app\"", with: "\"xid\":1")
        XCTAssertThrowsError(try decodeJSON(ScanItem.self, json))
    }

    func testUnknownFlagIsDroppedOnDecode() throws {
        let json = pinned.replacingOccurrences(of: "[\"sizeIncomplete\"]", with: "[\"inUse\",\"fromTheFuture\"]")
        XCTAssertEqual(try decodeJSON(ScanItem.self, json).flags, [.inUse])
    }

    func testFlagsEncodedSorted() throws {
        var i = ModelFixtures.item()
        i.flags = [.symlink, .inUse]
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: DiskKeeperJSON.makeEncoder().encode(i)) as? [String: Any])
        XCTAssertEqual(obj["flags"] as? [String], ["inUse", "symlink"])
    }

    func testSelectabilityTable() {
        let keep = ModelFixtures.item(tier: .keep)
        XCTAssertFalse(keep.isSelectable)
        let none = ModelFixtures.item(tier: .safe, cleanup: .none)
        XCTAssertFalse(none.isSelectable)
        let review = ModelFixtures.item(tier: .review)
        XCTAssertTrue(review.isSelectable)
        XCTAssertFalse(review.isBulkSelectable)
        let safe = ModelFixtures.item(tier: .safe, category: .aiToolData)
        XCTAssertTrue(safe.isBulkSelectable)
        let model = ModelFixtures.item(tier: .safe, category: .modelWeights)
        XCTAssertTrue(model.isSelectable)
        XCTAssertFalse(model.isBulkSelectable)
    }

    func testModelTypesAreSendable() {
        assertSendable(ScanItem.self)
        assertSendable(ScanResult.self)
        assertSendable(UsageTotals.self)
        assertSendable(ScanWarning.self)
        assertSendable(ScanWarning.Kind.self)
        assertSendable(ProjectRef.self)
        assertSendable(CleanupMethod.self)
        assertSendable(ItemFlag.self)
        assertSendable(ToolID.self)
        assertSendable(ItemCategory.self)
        assertSendable(RiskTier.self)
    }
}
