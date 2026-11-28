import XCTest
import protocol DiskKeeperCore.Scanner
@testable import DiskKeeperCore

final class UserPolicyAdjusterTests: XCTestCase {
    private var fx: FixtureHome!
    private var context: ScanContext!

    override func setUpWithError() throws {
        fx = try FixtureHome()
        context = ScanContext(environment: fx.env, pathGuard: try ScanGuard(environment: fx.env, protectPatterns: []),
                              now: Date(), maxConcurrentSizing: 1)
    }

    private func item(_ rel: String, rule: String = "t.r", tier: RiskTier = .safe) -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: fx.abs(rel)), displayName: rel, tool: "t", category: .aiToolData,
                 sizeAllocated: 10, sizeLogical: 10, fileCount: 1, lastModified: nil,
                 tier: tier, explanation: "x", ruleID: rule)
    }

    private func run(_ policy: UserPolicy, _ items: [ScanItem]) async -> (items: [ScanItem], warnings: [ScanWarning]) {
        let out = await UserPolicyAdjuster(policy: policy).adjust(items, context: context)
        XCTAssertTrue(AdjusterValidation.isMonotonic(before: items, after: out.items), "output must satisfy the adjuster contract")
        return out
    }

    func testEmptyPolicyChangesNothing() async {
        let items = [item("a"), item("b", tier: .review)]
        let out = await run(.empty, items)
        XCTAssertEqual(out.items, items)
        XCTAssertTrue(out.warnings.isEmpty)
    }

    func testIgnoredItemIDIsDropped() async {
        let a = item("a"), b = item("b")
        let out = await run(UserPolicy(ignoredItemIDs: [a.id]), [a, b])
        XCTAssertEqual(out.items.map(\.id), [b.id])
    }

    func testDisabledRuleDropsItsItems() async {
        let out = await run(UserPolicy(disabledRuleIDs: ["t.off"]), [item("a", rule: "t.off"), item("b", rule: "t.on")])
        XCTAssertEqual(out.items.map(\.ruleID), ["t.on"])
    }

    func testStricterOverrideApplied() async {
        let a = item("a"), b = item("b", tier: .review)
        let out = await run(UserPolicy(tierOverrides: [a.id: .keep, b.id: .keep]), [a, b])
        XCTAssertEqual(out.items.map(\.tier), [.keep, .keep])
        let rev = await run(UserPolicy(tierOverrides: ["t.r": .review]), [a])
        XCTAssertEqual(rev.items[0].tier, .review, "rule-id key works")
    }

    func testItemOverrideBeatsRuleOverride() async {
        let a = item("a")
        let out = await run(UserPolicy(tierOverrides: ["t.r": .keep, a.id: .review]), [a])
        XCTAssertEqual(out.items[0].tier, .review)
    }

    func testLooserOverridesAreIgnoredAndWarnedOnce() async {
        let k = item("k", tier: .keep), r = item("r", tier: .review)
        let out = await run(UserPolicy(tierOverrides: [k.id: .safe, r.id: .safe]), [k, r])
        XCTAssertEqual(out.items.map(\.tier), [.keep, .review])
        XCTAssertEqual(out.warnings.count, 2)
        let kr = await run(UserPolicy(tierOverrides: [k.id: .review]), [k])
        XCTAssertEqual(kr.items[0].tier, .keep, "Keep→Review is loosening")
    }

    func testUnknownIDsAreHarmless() async {
        let a = item("a")
        let out = await run(UserPolicy(ignoredItemIDs: ["nope"], disabledRuleIDs: ["x.y"], tierOverrides: ["zzz": .keep]), [a])
        XCTAssertEqual(out.items, [a])
        XCTAssertTrue(out.warnings.isEmpty)
    }

    func testEffectiveTierNeverLowers() {
        let a = item("a", tier: .review)
        XCTAssertEqual(UserPolicy(tierOverrides: [a.id: .safe]).effectiveTier(for: a), .review)
        XCTAssertEqual(UserPolicy(tierOverrides: [a.id: .keep]).effectiveTier(for: a), .keep)
    }

    func testRunsInsideTheEngineBeforeInUse() async throws {
        let a = item("a")
        let engine = ScanEngine(context: context, scanners: [FixedItems([a, item("b")])],
                                adjusters: [UserPolicyAdjuster(policy: UserPolicy(ignoredItemIDs: [a.id]))])
        var finished: ScanResult?
        for await e in try await engine.scan() { if case .finished(let r) = e { finished = r } }
        XCTAssertEqual(finished?.items.count, 1)
    }
}

private struct FixedItems: Scanner {
    let id = "fixed"
    var virtualNamespace: String? { nil }
    let items: [ScanItem]
    init(_ items: [ScanItem]) { self.items = items }
    func scan(context: ScanContext, sink: ScanSink) async throws { for i in items { await sink.item(i) } }
}
