import XCTest
@testable import DiskKeeperCore

final class BuildCachesRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
    private let file = "build-caches.json"

    private func run(_ f: FixtureHome) async throws -> HarnessResult {
        let r = try await RuleHarness.run(bundledFile: file, fixture: f, now: now)
        XCTAssertEqual(r.loadErrors, [])
        XCTAssertEqual(r.warnings.count, 0)
        for i in r.items where !i.path.hasPrefix(f.tmp.url.path + "/") { XCTFail("item outside the fixture: \(i.path)") }
        return r
    }

    @discardableResult
    private func make(_ f: FixtureHome, _ rel: String, days: Double) throws -> String {
        try f.file(rel + "/payload.bin", bytes: 4096, modified: ago(days: days))
        return try f.dir(rel, modified: ago(days: days))
    }

    func testModuleCacheIsReviewAndFreshIsKept() async throws {
        let rel = "Library/Developer/Xcode/DerivedData/ModuleCache.noindex"
        let old = try FixtureHome(); try make(old, rel, days: 40)
        let r = try await run(old)
        XCTAssertEqual(r.tier(old.abs(rel)), .review)
        XCTAssertEqual(r.item(old.abs(rel))?.cleanupMethod, .trash)
        let fresh = try FixtureHome(); try make(fresh, rel, days: 0.5)
        let rf = try await run(fresh)
        XCTAssertEqual(rf.tier(fresh.abs(rel)), .keep)
    }

    func testPnpmStorePathsWithAndWithoutPnpmHome() async throws {
        let defaults = ["Library/pnpm/store", ".local/share/pnpm/store"]
        for rel in defaults {
            let f = try FixtureHome(); try make(f, rel, days: 40)
            let r = try await run(f)
            XCTAssertEqual(r.items.map(\.path), [f.abs(rel)])
            XCTAssertEqual(r.tier(f.abs(rel)), .review)
            XCTAssertEqual(r.items.first?.ruleID, "build-caches.pnpm-store")
        }
        let custom = try FixtureHome()
        custom.env = PathEnvironment(home: custom.home, temporaryDirectory: custom.tempDir,
                                     variables: ["PNPM_HOME": custom.abs("pnpmhome")])
        try make(custom, "pnpmhome/store", days: 40)
        try make(custom, "Library/pnpm/store", days: 40)
        let r = try await run(custom)
        XCTAssertEqual(Set(r.paths), [custom.abs("pnpmhome/store"), custom.abs("Library/pnpm/store")])

        let same = try FixtureHome()   // PNPM_HOME pointing at the default is one item, not two
        same.env = PathEnvironment(home: same.home, temporaryDirectory: same.tempDir,
                                   variables: ["PNPM_HOME": same.abs("Library/pnpm")])
        try make(same, "Library/pnpm/store", days: 40)
        let rs = try await run(same)
        XCTAssertEqual(rs.items.count, 1)

        let fresh = try FixtureHome(); try make(fresh, defaults[0], days: 0.5)
        let rfresh = try await run(fresh)
        XCTAssertEqual(rfresh.tier(fresh.abs(defaults[0])), .keep)
    }

    func testTartOCIItemsAreImageFoldersAndSymlinksAreNotFollowed() async throws {
        let f = try FixtureHome()
        let org = ".tart/cache/OCIs/ghcr.io/cirruslabs"
        let digest = try make(f, org + "/macos-base/sha256:abc", days: 40)
        try f.symlink(org + "/macos-base/latest", to: digest)
        let outside = try make(f, "outside-image", days: 40)
        try f.symlink(org + "/escape", to: outside)                 // a symlinked image folder is not an item
        try make(f, org + "/other/sha256:def", days: 0.5)
        let r = try await run(f)
        XCTAssertEqual(r.paths, [f.abs(org + "/macos-base"), f.abs(org + "/other")])
        XCTAssertEqual(r.tier(f.abs(org + "/macos-base")), .review)
        XCTAssertEqual(r.tier(f.abs(org + "/other")), .keep)
        XCTAssertTrue(r.items.allSatisfy { $0.ruleID == "build-caches.tart-oci" })
    }

    func testTartVMsAreReportOnlyAndNeverSafe() async throws {
        for days in [0.1, 3, 400] {
            let f = try FixtureHome()
            try make(f, ".tart/vms/dev-vm", days: days)
            let r = try await run(f)
            let item = try XCTUnwrap(r.item(f.abs(".tart/vms/dev-vm")))
            XCTAssertEqual(item.cleanupMethod, .none)
            XCTAssertNotEqual(item.tier, .safe)
            XCTAssertFalse(item.isSelectable)
            XCTAssertTrue(item.explanation.hasPrefix("Not regenerable:"))
            XCTAssertTrue(item.explanation.contains("tart delete"))
        }
    }

    func testAbsentGivesNothing() async throws {
        let r = try await run(try FixtureHome())
        XCTAssertTrue(r.items.isEmpty)
    }

    func testFileLevelConventions() throws {
        let url = try XCTUnwrap(CoreResources.rulesDirectoryURL?.appendingPathComponent(file))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let rules = try XCTUnwrap(json?["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 4)
        for rule in rules {
            let id = try XCTUnwrap(rule["id"] as? String)
            let e = try XCTUnwrap(rule["explanation"] as? String)
            XCTAssertTrue(e.hasPrefix("Regenerable:") || e.hasPrefix("Not regenerable:"), id)
            let vi = try XCTUnwrap((rule["localized"] as? [String: Any])?["vi"] as? [String: String], id)
            XCTAssertFalse(vi["title"]?.isEmpty ?? true, id)
            XCTAssertFalse(vi["explanation"]?.isEmpty ?? true, id)
            XCTAssertNil(rule["protect"])
        }
        // Only report-only VMs say "Not regenerable"; nothing in this file may name a tool command.
        XCTAssertNil(json?["protect"])
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("toolCommand"))
    }

    func testNoRuleReachesProtectedPaths() async throws {
        let f = try FixtureHome()
        let loaded = try RuleHarness.loadRules(json: String(decoding: try Data(contentsOf: XCTUnwrap(
            CoreResources.rulesDirectoryURL?.appendingPathComponent(file))), as: UTF8.self), fixture: f)
        XCTAssertEqual(loaded.errors, [])
        let guardrail = try ScanGuard(environment: f.env, protectPatterns: loaded.protectPatterns)
        for rule in loaded.allRules {
            for p in rule.expandedPaths { XCTAssertTrue(guardrail.check(p).isAllowed, "\(rule.rule.id): \(p)") }
        }
    }

    func testCatalogMembershipAndHints() {
        XCTAssertTrue(BuildCacheCatalog.lists(ruleID: "build-caches.tart-oci"))
        XCTAssertTrue(BuildCacheCatalog.lists(ruleID: "dev-caches.go-mod"))
        XCTAssertTrue(BuildCacheCatalog.lists(ruleID: "system.pip-cache"))
        XCTAssertFalse(BuildCacheCatalog.lists(ruleID: "system.agent-temp"))
        XCTAssertFalse(BuildCacheCatalog.lists(ruleID: "claude-code.transcripts"))
        XCTAssertEqual(BuildCacheCatalog.family(ruleID: "build-caches.xcode-deriveddata"), .xcode)
        XCTAssertEqual(BuildCacheCatalog.family(ruleID: "build-caches.tart-vms"), .vms)
        XCTAssertEqual(BuildCacheCatalog.hints(forRuleIDs: ["dev-caches.go-build", "dev-caches.yarn"]).map(\.command), ["go clean -cache"])
        XCTAssertTrue(BuildCacheCatalog.hints(forRuleIDs: []).isEmpty)
    }
}
