import XCTest
@testable import DiskKeeperCore

final class TierEvaluatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func rule(tierWhen: String) throws -> ScannerRule {
        let json = RuleFixtures.file(rules: [RuleFixtures.rule(tier: "review", extra: #""tierWhen": \#(tierWhen)"#)])
        return try JSONDecoder().decode(RuleFile.self, from: Data(json.utf8)).rules[0]
    }

    private func facts(ageDays: Double?, size: Int64 = 0, markers: Set<String> = []) -> ItemFacts {
        ItemFacts(lastModified: ageDays.map { now.addingTimeInterval(-$0 * day) }, sizeAllocated: size,
                  existingMarkers: markers)
    }

    func testMostRestrictiveWins() throws {
        let r = try rule(tierWhen: #"[{"if": {"newerThanDays": 7}, "tier": "keep"}, {"if": {"olderThanDays": 30}, "tier": "safe"}, {"if": {"newerThanDays": 100}, "tier": "keep"}]"#)
        let fresh = TierEvaluator.evaluate(r, facts: facts(ageDays: 1), now: now)
        XCTAssertEqual(fresh.tier, .keep)
        XCTAssertEqual(fresh.matchedIndex, 0)
        // 40 days: entries 1 (safe) and 2 (keep) both match; keep wins, first entry with that tier reported.
        let mid = TierEvaluator.evaluate(r, facts: facts(ageDays: 40), now: now)
        XCTAssertEqual(mid.tier, .keep)
        XCTAssertEqual(mid.matchedIndex, 2)
        // Only the "safe" entry matches.
        let old = TierEvaluator.evaluate(r, facts: facts(ageDays: 500), now: now)
        XCTAssertEqual(old.tier, .safe)
        XCTAssertEqual(old.matchedIndex, 1)
        let none = TierEvaluator.evaluate(r, facts: facts(ageDays: nil), now: now)
        XCTAssertEqual(none.tier, .review)
        XCTAssertNil(none.matchedIndex)
    }

    func testEntryOrderNeverMatters() throws {
        let safeFirst = try rule(tierWhen: #"[{"if": {"sizeOverMB": 1}, "tier": "safe"}, {"if": {"newerThanDays": 7}, "tier": "keep"}]"#)
        let keepFirst = try rule(tierWhen: #"[{"if": {"newerThanDays": 7}, "tier": "keep"}, {"if": {"sizeOverMB": 1}, "tier": "safe"}]"#)
        let f = facts(ageDays: 1, size: 5_000_000)
        XCTAssertEqual(TierEvaluator.evaluate(safeFirst, facts: f, now: now).tier, .keep)
        XCTAssertEqual(TierEvaluator.evaluate(keepFirst, facts: f, now: now).tier, .keep)
        // keep > review > safe among matches
        let mixed = try rule(tierWhen: #"[{"if": {"sizeOverMB": 1}, "tier": "safe"}, {"if": {"sizeOverMB": 2}, "tier": "review"}]"#)
        XCTAssertEqual(TierEvaluator.evaluate(mixed, facts: f, now: now).tier, .review)
    }

    func testStrictBoundaries() throws {
        let r = try rule(tierWhen: #"[{"if": {"newerThanDays": 7}, "tier": "keep"}, {"if": {"olderThanDays": 7}, "tier": "safe"}]"#)
        XCTAssertEqual(TierEvaluator.evaluate(r, facts: facts(ageDays: 7), now: now).tier, .review)
        XCTAssertEqual(TierEvaluator.evaluate(r, facts: facts(ageDays: 7.001), now: now).tier, .safe)
        XCTAssertEqual(TierEvaluator.evaluate(r, facts: facts(ageDays: 6.999), now: now).tier, .keep)
    }

    func testNilLastModifiedSkipsAgeConditions() throws {
        let r = try rule(tierWhen: #"[{"if": {"newerThanDays": 7}, "tier": "keep"}, {"if": {"olderThanDays": 7}, "tier": "safe"}]"#)
        XCTAssertEqual(TierEvaluator.evaluate(r, facts: facts(ageDays: nil), now: now).tier, .review)
    }

    func testFutureMTimeIsNew() throws {
        let r = try rule(tierWhen: #"[{"if": {"newerThanDays": 1}, "tier": "keep"}]"#)
        XCTAssertEqual(TierEvaluator.evaluate(r, facts: facts(ageDays: -30), now: now).tier, .keep)
        let old = try rule(tierWhen: #"[{"if": {"olderThanDays": 1}, "tier": "safe"}]"#)
        XCTAssertEqual(TierEvaluator.evaluate(old, facts: facts(ageDays: -30), now: now).tier, .review)
    }

    func testSizeOverMBDecimal() throws {
        let r = try rule(tierWhen: #"[{"if": {"sizeOverMB": 1}, "tier": "keep"}]"#)
        XCTAssertEqual(TierEvaluator.evaluate(r, facts: facts(ageDays: 1, size: 1_000_001), now: now).tier, .keep)
        XCTAssertEqual(TierEvaluator.evaluate(r, facts: facts(ageDays: 1, size: 1_000_000), now: now).tier, .review)
    }

    func testANDOfKeys() throws {
        let r = try rule(tierWhen: #"[{"if": {"olderThanDays": 30, "sizeOverMB": 10}, "tier": "safe"}]"#)
        XCTAssertEqual(TierEvaluator.evaluate(r, facts: facts(ageDays: 40, size: 20_000_000), now: now).tier, .safe)
        XCTAssertEqual(TierEvaluator.evaluate(r, facts: facts(ageDays: 40, size: 1), now: now).tier, .review)
        XCTAssertEqual(TierEvaluator.evaluate(r, facts: facts(ageDays: 1, size: 20_000_000), now: now).tier, .review)
    }

    func testMarkerExists() throws {
        let r = try rule(tierWhen: #"[{"if": {"markerExists": ".git"}, "tier": "keep"}]"#)
        XCTAssertEqual(TierEvaluator.evaluate(r, facts: facts(ageDays: 1, markers: [".git"]), now: now).tier, .keep)
        XCTAssertEqual(TierEvaluator.evaluate(r, facts: facts(ageDays: 1), now: now).tier, .review)
    }
}
