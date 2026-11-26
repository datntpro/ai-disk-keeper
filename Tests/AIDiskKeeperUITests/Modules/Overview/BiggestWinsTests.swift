import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

final class BiggestWinsTests: XCTestCase {
    private func item(_ path: String, _ size: Int64, category: ItemCategory = .aiToolData, tier: RiskTier = .safe,
                      explanation: String = "Why. More.") -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: path), displayName: (path as NSString).lastPathComponent, tool: .claudeCode,
                 category: category, sizeAllocated: size, sizeLogical: size, fileCount: 1, lastModified: nil, tier: tier,
                 explanation: explanation, ruleID: "r")
    }

    func testTopThreeBySizeMixesTiers() {
        let items = [item("/a/1", 100), item("/a/2", 900, tier: .review), item("/a/3", 500, tier: .keep),
                     item("/a/4", 700), item("/a/5", 50)]
        let top = BiggestWins.top(items)
        XCTAssertEqual(top.map(\.path), ["/a/2", "/a/4", "/a/3"])
        XCTAssertEqual(Set(top.map(\.tier)), [.review, .safe, .keep])
    }

    func testNestedItemsAreDedupedAcrossStages() {
        let items = [item("/h/Library/App", 1000, category: .appLeftover), item("/h/Library/App/Logs", 400),
                     item("/h/other", 300), item("/h/Library/AppX", 200), item("/h/z", 100)]
        let top = BiggestWins.top(items)
        XCTAssertEqual(top.map(\.path), ["/h/Library/App", "/h/other", "/h/Library/AppX"])   // "/AppX" is not inside "/App"
    }

    func testZeroByteItemsNeverWin() {
        XCTAssertTrue(BiggestWins.top([item("/a", 0)]).isEmpty)
    }

    func testDestinations() {
        let enabled: Set<ModuleID> = [.aiTools, .largeOld, .duplicates]
        XCTAssertEqual(BiggestWins.destination(for: [item("/a", 5)], enabled: enabled), .module(.aiTools))
        XCTAssertEqual(BiggestWins.destination(for: [item("/a", 5, category: .largeFile)], enabled: enabled), .module(.largeOld))
        XCTAssertEqual(BiggestWins.destination(for: [item("/a", 5, category: .systemJunk)], enabled: enabled), .category(.systemJunk))
        XCTAssertNil(BiggestWins.destination(for: [], enabled: enabled))
    }

    func testWhyIsTheFirstSentence() {
        XCTAssertEqual(BiggestWins.why(item("/a", 1, explanation: "Caches are rebuilt. Safe to remove.")), "Caches are rebuilt.")
        XCTAssertEqual(BiggestWins.why(item("/a", 1, explanation: "No full stop")), "No full stop")
    }

    func testModuleTargets() {
        XCTAssertEqual(OverviewTarget.selection(for: .systemJunk), .category(.systemJunk))
        XCTAssertEqual(OverviewTarget.selection(for: .aiTools), .module(.aiTools))
        XCTAssertEqual(OverviewTarget.selection(for: .apps), .module(.uninstaller))
        XCTAssertEqual(OverviewTarget.selection(for: .startup), .module(.startupItems))
    }

    func testStrataSegmentsNeverGoNegativeAndEndWithEverythingElse() {
        let items = [item("/a", 400), item("/b", 300, category: .systemJunk)]
        let seg = OverviewStrata.segments(items: items, appsBytes: 100, used: 1000, scanned: true)
        XCTAssertEqual(seg.map(\.bytes).reduce(0, +), 1000)
        XCTAssertEqual(seg.last?.bytes, 200)
        XCTAssertEqual(seg.last?.id, "overview.rest")
        let over = OverviewStrata.segments(items: items, appsBytes: 100, used: 500, scanned: true)
        XCTAssertFalse(over.contains { $0.id == "overview.rest" })
        XCTAssertTrue(over.allSatisfy { $0.bytes >= 0 })
        let before = OverviewStrata.segments(items: [], appsBytes: 0, used: 700, scanned: false)
        XCTAssertEqual(before.map(\.bytes), [700])
    }

    func testTilesShowOnlyEnabledModulesWithSummaries() {
        let sums: [CareModule: ModuleSummary] = [
            .aiTools: ModuleSummary(module: .aiTools, safeBytes: 1, itemCount: 1),
            .apps: ModuleSummary(module: .apps, safeBytes: 1, itemCount: 1),
            .startup: ModuleSummary(module: .startup),
            .systemJunk: ModuleSummary(module: .systemJunk, safeBytes: 1, itemCount: 1),
        ]
        XCTAssertEqual(OverviewModuleTiles.tiles(summaries: sums, enabled: [.aiTools, .startupItems]), [.aiTools, .systemJunk])
        XCTAssertEqual(OverviewModuleTiles.tiles(summaries: sums, enabled: [.aiTools, .uninstaller]), [.aiTools, .systemJunk, .apps])
    }
}
