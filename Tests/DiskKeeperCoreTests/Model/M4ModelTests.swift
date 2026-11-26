import XCTest
@testable import DiskKeeperCore

final class M4ModelTests: CleanupTestCase {
    private let newCategories: [ItemCategory] = [.largeFile, .duplicate, .application, .appLeftover, .startupItem]

    func testCategoryRawValuesAppendOnly() {
        XCTAssertEqual(ItemCategory.allCases.map(\.rawValue),
                       ["aiToolData", "worktree", "buildArtifact", "modelWeights", "systemJunk", "docker",
                        "largeFile", "duplicate", "application", "appLeftover", "startupItem"])
    }

    func testNewCategoriesRoundTrip() throws {
        for c in newCategories {
            let item = ModelFixtures.item(category: c)
            XCTAssertEqual(try ModelFixtures.roundTrip(item), item)
            XCTAssertFalse(c.displayName.isEmpty)
        }
    }

    func testRuleCategoriesAreTheOriginalSix() {
        XCTAssertEqual(ItemCategory.ruleCategories,
                       [.aiToolData, .worktree, .buildArtifact, .modelWeights, .systemJunk, .docker])
        for c in newCategories { XCTAssertFalse(c.isRuleCategory) }
    }

    func testNeverBulkSelectableSet() {
        let never = Set(ItemCategory.allCases.filter(\.isNeverBulkSelectable))
        XCTAssertEqual(never, Set(newCategories + [.modelWeights]))
    }

    func testPersonalCategoriesNeverBulkSelectable() {
        for c in newCategories + [.modelWeights] {
            let item = ModelFixtures.item(tier: .safe, category: c, cleanup: .trash)
            XCTAssertTrue(item.isSelectable, "\(c)")
            XCTAssertFalse(item.isBulkSelectable, "\(c)")
        }
        XCTAssertTrue(ModelFixtures.item(tier: .safe, category: .systemJunk).isBulkSelectable)
    }

    func testGroupIDRoundTrip() throws {
        var item = ModelFixtures.item(category: .duplicate)
        item.groupID = "dup:ab12:1048576"
        let back = try ModelFixtures.roundTrip(item)
        XCTAssertEqual(back, item)
        XCTAssertEqual(back.groupID, "dup:ab12:1048576")
    }

    func testItemWithoutGroupEncodesWithoutKey() throws {
        let item = ModelFixtures.item()
        let json = try ModelFixtures.jsonString(item)
        XCTAssertFalse(json.contains("groupID"))
        XCTAssertTrue(json.contains("\"flags\":[]"))
        // Same bytes as an item built through the pre-T28 init shape (no groupID argument).
        let legacy = ScanItem(url: URL(fileURLWithPath: "/Users/test/a"), displayName: "n", tool: .claudeCode,
                              category: .aiToolData, sizeAllocated: 100, sizeLogical: 90, fileCount: 1,
                              lastModified: ModelFixtures.date, tier: .safe, explanation: "e", ruleID: "r")
        XCTAssertEqual(json, try ModelFixtures.jsonString(legacy))
    }

    func testOldJSONStillDecodes() throws {
        let json = """
        {"category":"aiToolData","cleanup":{"kind":"trash"},"displayName":"n","explanation":"e","fileCount":1,
         "flags":["sizeIncomplete"],"id":"r|/Users/test/a","path":"/Users/test/a","ruleID":"r",
         "sizeAllocated":100,"sizeLogical":90,"tier":"safe","tool":"claude-code"}
        """
        let item = try ModelFixtures.decodeJSON(ScanItem.self, json)
        XCTAssertNil(item.groupID)
        XCTAssertEqual(item.flags, [.sizeIncomplete])
    }

    func testNewFlagsRoundTripAndUnknownFlagsIgnored() throws {
        let json = """
        {"category":"duplicate","cleanup":{"kind":"trash"},"displayName":"n","explanation":"e","fileCount":1,
         "flags":["dataless","suggestedKeeper","futureFlag"],"id":"r|/Users/test/a","path":"/Users/test/a",
         "ruleID":"r","sizeAllocated":100,"sizeLogical":90,"tier":"safe","tool":"files"}
        """
        let item = try ModelFixtures.decodeJSON(ScanItem.self, json)
        XCTAssertEqual(item.flags, [.dataless, .suggestedKeeper])
        XCTAssertEqual(try ModelFixtures.roundTrip(item), item)
    }

    func testTrashApplicationCodable() throws {
        let m = CleanupMethod.trashApplication(bundleID: "com.example.App")
        let json = try ModelFixtures.jsonString(m)
        XCTAssertTrue(json.contains("\"kind\":\"trashApplication\""))
        XCTAssertTrue(json.contains("\"bundleID\":\"com.example.App\""))
        XCTAssertEqual(try ModelFixtures.decodeJSON(CleanupMethod.self, json), m)
        XCTAssertTrue(m.isActionable)
    }

    func testTrashApplicationRejectsBadBundleID() {
        for bad in ["", "no spaces allowed", "../x"] {
            let json = "{\"kind\":\"trashApplication\",\"bundleID\":\"\(bad)\"}"
            XCTAssertThrowsError(try ModelFixtures.decodeJSON(CleanupMethod.self, json), bad) {
                XCTAssertTrue($0 is DecodingError)
            }
        }
        XCTAssertThrowsError(try ModelFixtures.decodeJSON(CleanupMethod.self, "{\"kind\":\"trashApplication\"}"))
    }

    func testUnknownCleanupKindStillThrows() {
        XCTAssertThrowsError(try ModelFixtures.decodeJSON(CleanupMethod.self, "{\"kind\":\"nope\"}"))
    }

    func testToolIDFilesAndApps() {
        for t in [ToolID.files, .apps] {
            XCTAssertTrue(ToolID.isValid(t.rawValue))
            XCTAssertTrue(ToolID.wellKnown.contains(t))
        }
        XCTAssertEqual(ToolID.files.knownDisplayName, "Your files")
        XCTAssertEqual(ToolID.apps.knownDisplayName, "Applications")
    }

    func testScanResultTotalsIncludeNewCategories() {
        let items = ItemCategory.allCases.enumerated().map { i, c in
            ModelFixtures.item(path: "/Users/test/\(i)", category: c, allocated: Int64(10 * (i + 1)), ruleID: "r\(i)")
        }
        let result = ScanResult(items: items, warnings: [], startedAt: Date(), finishedAt: Date(), wasCancelled: false)
        let byCat = result.totalsByCategory
        XCTAssertEqual(byCat.count, ItemCategory.allCases.count)
        XCTAssertEqual(byCat.values.reduce(0) { $0 + $1.allocatedBytes }, result.total.allocatedBytes)
        XCTAssertEqual(byCat[.startupItem]?.allocatedBytes, 110)
    }

    func testTrashApplicationIsNotSupportedYet() async throws {
        try fx.file("home/cache/App.app/f", bytes: 10)
        let it = try item("home/cache/App.app", method: .trashApplication(bundleID: "com.example.App"))
        let engine = try makeEngine()
        let plan = await engine.plan([it])
        XCTAssertEqual(plan.entries[0].blockers, [.methodNotSupported("trashApplication")])
        let report = try await engine.execute(plan)
        XCTAssertEqual(report.results.count, 1)
        XCTAssertTrue(exists("home/cache/App.app/f"))
        XCTAssertTrue(trashContents().isEmpty)
    }
}
