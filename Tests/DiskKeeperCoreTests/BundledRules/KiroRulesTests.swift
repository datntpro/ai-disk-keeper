import XCTest
@testable import DiskKeeperCore

final class KiroRulesTests: XCTestCase {
    private let f = "kiro.json"
    private let app = "Library/Application Support/Kiro"
    private let crew = "Library/Application Support/kirocrew-desktop"

    private func populate(_ fx: FixtureHome) throws {
        try OtherToolRules.agedDir(fx, ".kiro/logs/old", days: 5)
        try fx.file(".kiro/logs/new/x.log", modified: OtherToolRules.days(0.1))
        try fx.dir(".kiro/logs/new", modified: OtherToolRules.days(0.1))
        for e in ["Cache", "CachedData", "GPUCache", "CachedProfilesData"] { try fx.file("\(app)/\(e)/blob", bytes: 10) }
        try OtherToolRules.agedDir(fx, "\(app)/logs/old", days: 5)
        try OtherToolRules.agedDir(fx, "\(app)/User/workspaceStorage/ws-old", days: 20)
        try OtherToolRules.agedDir(fx, "\(app)/User/workspaceStorage/ws-new", days: 3)
        try fx.file(".kiro/crew/models/embed.gguf", bytes: 10)
        try fx.file(".kiro/crew/models/readme.txt")
        try fx.file(".kiro/crew/browser-harness/chromium/chrome", bytes: 10)
        try OtherToolRules.agedDir(fx, ".kiro/crew/app-adoption", days: 20)
        try fx.file(".kiro/crew/app-adoption/old.tar.gz", bytes: 10, modified: OtherToolRules.days(20))
        try fx.file(".kiro/crew/app-adoption/new.tar.gz", bytes: 10, modified: OtherToolRules.days(2))
        try fx.file(".kiro/crew/app-adoption/other.txt", modified: OtherToolRules.days(20))
        for e in ["Cache", "GPUCache"] { try fx.file("\(crew)/\(e)/blob", bytes: 10) }
    }

    func testKiroAbsentProducesNothing() async throws { try await OtherToolRules.assertAbsent(f) }

    func testKiroFileLoadsWithRealGuard() throws { try OtherToolRules.assertLoads(f, tool: "kiro") }

    func testKiroRulesFindFixtureItems() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(r.pairs, [
            ".kiro/logs/old:safe", ".kiro/logs/new:keep",
            "\(app)/Cache:safe", "\(app)/CachedData:safe", "\(app)/GPUCache:safe", "\(app)/CachedProfilesData:safe",
            "\(app)/logs/old:safe", "\(app)/User/workspaceStorage/ws-old:review", "\(app)/User/workspaceStorage/ws-new:keep",
            ".kiro/crew/models/embed.gguf:review", ".kiro/crew/browser-harness/chromium:review",
            ".kiro/crew/app-adoption/old.tar.gz:review", ".kiro/crew/app-adoption/new.tar.gz:keep",
            "\(crew)/Cache:safe", "\(crew)/GPUCache:safe",
        ].sorted())
    }

    func testElectronCachesSafeAndRequireQuit() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        let main = r.items.filter { $0.ruleID == "kiro.electron-cache" }
        XCTAssertEqual(main.count, 4)
        for c in main { XCTAssertEqual(c.tier, .safe); XCTAssertEqual(c.requiresAppQuit, "dev.kiro.desktop") }
        let crewItems = r.items.filter { $0.ruleID == "kiro.crew-desktop-cache" }
        XCTAssertEqual(crewItems.count, 2)
        for c in crewItems { XCTAssertEqual(c.tier, .safe); XCTAssertEqual(c.requiresAppQuit, "com.amazon.kiro.crew") }
    }

    func testWorkspaceStorageReviewAndKeepWhenFresh() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertEqual(r.tier("\(app)/User/workspaceStorage/ws-old"), .review)
        XCTAssertEqual(r.tier("\(app)/User/workspaceStorage/ws-new"), .keep)
    }

    func testAppLogsRequireQuit() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        let logs = r.items.filter { $0.ruleID == "kiro.app-logs" }
        XCTAssertFalse(logs.isEmpty)
        for l in logs { XCTAssertEqual(l.requiresAppQuit, "dev.kiro.desktop") }
    }

    func testKiroModelIsModelWeightsReview() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        let m = try XCTUnwrap(r.item(".kiro/crew/models/embed.gguf"))
        XCTAssertEqual(m.category, .modelWeights)
        XCTAssertEqual(m.tier, .review)
        XCTAssertFalse(m.isBulkSelectable)
        XCTAssertNil(r.item(".kiro/crew/models/readme.txt"))
    }

    func testKiroBrowserProfileProtected() async throws {
        try await OtherToolRules.assertProtected(f, files: [
            ".kiro/crew/browser-profile/Default/Cookies", ".kiro/crew/browser-profile/Local State",
            ".kiro/crew/browser-harness/venv/bin/python",
        ])
    }

    func testKiroProtectedFilesNeverItems() async throws {
        try await OtherToolRules.assertProtected(f, files: [
            ".kiro/settings/mcp.json", ".kiro/steering/s.md", ".kiro/agents/a.json", ".kiro/identities/i", ".kiro/mates/m",
            ".kiro/powers/p", ".kiro/x.json", ".kiro/crew-auth-staging/t", ".kiro/crew/auth-store-staging/t", ".kiro/crew/state.json",
            "\(app)/User/globalStorage/state.vscdb", "\(app)/User/settings.json", "\(app)/Cookies", "\(app)/Local Storage/l/1",
            "\(app)/Session Storage/1", "\(app)/IndexedDB/d/1", "\(app)/Local State", "\(app)/Preferences",
            "\(crew)/Cookies", "\(crew)/Local Storage/l/1", "\(crew)/Preferences",
        ])
    }

    func testRuleTitlesAreUniqueAndCased() throws {
        let fx = try FixtureHome()
        let loaded = RuleLoader(environment: fx.env, bundledRulesDirectory: CoreResources.rulesDirectoryURL,
                                userRulesDirectory: nil, guardFactory: ScanGuard.loaderFactory(environment: fx.env)).load()
        for tool in ["kiro", "orca"] {
            let rules = loaded.allRules.filter { $0.tool.rawValue == tool }.map(\.rule)
            XCTAssertEqual(Set(rules.map(\.title)).count, rules.count, "duplicate titles in \(tool)")
            for r in rules { XCTAssertFalse(r.explanation.contains("kirocrew-desktop is"), r.id)
                             XCTAssertFalse(r.explanation.hasPrefix("orca is"), r.id) }
        }
    }

    func testKiroDoesNotTargetKiroRoots() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        try fx.file(".kiro/sessions/s1/x")
        let r = try await OtherToolRules.run(f, fx)
        for banned in [".kiro", ".kiro/crew", ".kiro/sessions", ".kiro/sessions/s1"] {
            XCTAssertNil(r.item(banned), banned)
        }
    }

    func testKiroReadOnly() async throws { try await OtherToolRules.assertReadOnly(f, populate: populate) }
}
