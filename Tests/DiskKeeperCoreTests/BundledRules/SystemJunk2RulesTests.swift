import XCTest
@testable import DiskKeeperCore

final class SystemJunk2RulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
    private let file = "system-junk-2.json"

    private func run(_ f: FixtureHome, bundled: String? = nil) async throws -> HarnessResult {
        let r = try await RuleHarness.run(bundledFile: bundled ?? file, fixture: f, now: now,
                                          overridePaths: ["system.agent-temp": [f.tempDir]])
        XCTAssertEqual(r.loadErrors, [])
        let root = f.tmp.url.path
        for i in r.items where !i.path.hasPrefix(root + "/") { XCTFail("item outside the fixture: \(i.path)") }
        return r
    }

    @discardableResult
    private func make(_ f: FixtureHome, _ rel: String, days: Double) throws -> String {
        try f.file(rel + "/payload.bin", bytes: 4096, modified: ago(days: days))
        return try f.dir(rel, modified: ago(days: days))
    }

    // MARK: installers

    func testInstallers() async throws {
        let f = try FixtureHome()
        try f.file("Downloads/old.dmg", modified: ago(days: 31))
        try f.file("Downloads/old.pkg", modified: ago(days: 90))
        try f.file("Downloads/Xcode.xip", modified: ago(days: 60))
        try f.file("Downloads/new.dmg", modified: ago(days: 10))
        try f.file("Downloads/UPPER.DMG", modified: ago(days: 40))
        try f.file("Downloads/foo.dmg.part", modified: ago(days: 40))
        try f.file("Downloads/notes.txt", modified: ago(days: 40))
        try make(f, "Downloads/dir.dmg", days: 40)
        let r = try await run(f)
        XCTAssertEqual(r.tier(f.abs("Downloads/old.dmg")), .review)
        XCTAssertEqual(r.tier(f.abs("Downloads/old.pkg")), .review)
        XCTAssertEqual(r.tier(f.abs("Downloads/Xcode.xip")), .review)
        XCTAssertEqual(r.tier(f.abs("Downloads/new.dmg")), .keep)
        XCTAssertEqual(r.tier(f.abs("Downloads/UPPER.DMG")), .review)
        XCTAssertNil(r.item(f.abs("Downloads/foo.dmg.part")))
        XCTAssertNil(r.item(f.abs("Downloads/notes.txt")))
        XCTAssertNil(r.item(f.abs("Downloads/dir.dmg")), "a directory is not an installer file")
        XCTAssertEqual(r.items.filter { $0.ruleID.hasPrefix("system.installers.") }.count, 5)
        XCTAssertFalse(r.items.contains { $0.tier == .safe })
    }

    func testAbsentDownloadsIsQuiet() async throws {
        let f = try FixtureHome()
        let r = try await run(f)
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertTrue(r.warnings.isEmpty)
    }

    // MARK: iOS backups

    func testIOSBackupsNeverSafe() async throws {
        let f = try FixtureHome()
        let b = "Library/Application Support/MobileSync/Backup"
        try make(f, "\(b)/00008030-001C5C2A3C03802E", days: 2000)
        try make(f, "\(b)/new-one", days: 0.1)
        let r = try await run(f)
        XCTAssertEqual(r.tier(f.abs("\(b)/00008030-001C5C2A3C03802E")), .review)
        XCTAssertEqual(r.tier(f.abs("\(b)/new-one")), .review)
        XCTAssertFalse(r.items.contains { $0.tier == .safe })
    }

    // MARK: generic app caches

    func testAppCaches() async throws {
        let f = try FixtureHome()
        try make(f, "Library/Caches/com.example.App", days: 40)
        try make(f, "Library/Caches/com.example.Fresh", days: 0.5)
        try make(f, "Library/Caches/com.apple.Safari", days: 40)
        try make(f, "Library/Caches/Homebrew", days: 40)
        try make(f, "Library/Caches/foo.bar baz", days: 40)
        try make(f, "Library/Caches/org.swift.swiftpm", days: 40)
        try make(f, "Library/Caches/com.anthropic.claudefordesktop", days: 40)
        try make(f, "Library/Caches/CloudKit", days: 40)
        try make(f, "Library/Caches/com.example.App.savedState", days: 40)
        try f.file("Library/Caches/file.with.dots", modified: ago(days: 40))
        let r = try await run(f)
        let generic = r.items.filter { $0.ruleID == "system.app-caches" }
        XCTAssertEqual(Set(generic.map(\.path)), [f.abs("Library/Caches/com.example.App"), f.abs("Library/Caches/com.example.Fresh")])
        let app = try XCTUnwrap(r.item(f.abs("Library/Caches/com.example.App")))
        XCTAssertEqual(app.tier, .safe)
        XCTAssertEqual(app.requiresAppQuit, "com.example.App")
        XCTAssertEqual(r.tier(f.abs("Library/Caches/com.example.Fresh")), .keep)
        XCTAssertEqual(r.item(f.abs("Library/Caches/com.example.Fresh"))?.requiresAppQuit, "com.example.Fresh")
    }

    func testClaudeCacheStaysWithItsOwnRule() async throws {
        let f = try FixtureHome()
        try make(f, "Library/Caches/com.anthropic.claudefordesktop", days: 40)
        let generic = try await run(f)
        XCTAssertTrue(generic.items.isEmpty)
        let junk = try await run(f, bundled: "system-junk.json")
        let hits = junk.items.filter { $0.path == f.abs("Library/Caches/com.anthropic.claudefordesktop") }
        XCTAssertEqual(hits.map(\.ruleID), ["system.app-cache.claude"])
    }

    // MARK: cross-file consistency

    private func allRules() throws -> [(ScannerRule, file: String)] {
        let dir = try XCTUnwrap(CoreResources.rulesDirectoryURL)
        var out: [(ScannerRule, file: String)] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where name.hasSuffix(".json") {
            let f = try JSONDecoder().decode(RuleFile.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
            for r in f.rules { out.append((r, name)) }
        }
        return out
    }

    func testGenericCachesRuleExcludesEveryOtherCachesRule() throws {
        let rules = try allRules()
        let generic = try XCTUnwrap(rules.first { $0.0.id == "system.app-caches" }?.0)
        let excludes = generic.match.exclude
        func excluded(_ name: String) -> Bool { excludes.contains { $0.matchesEither(name) } }
        func claimedByGeneric(_ name: String) -> Bool {
            (generic.match.glob?.matchesEither(name) ?? true) && !excluded(name)
        }
        let cachesPrefix = "$CACHES"
        var checked = 0
        for (rule, _) in rules where rule.id != generic.id {
            for p in rule.paths where p.raw == cachesPrefix && rule.match.kind == .children {
                // another children rule rooted at $CACHES: its glob must be excluded by the generic rule
                // (the pattern text itself is matched, since the globs are written to line up)
                let g = rule.match.glob?.pattern ?? "*"
                if g.contains(where: { "*?[".contains($0) }) {
                    XCTAssertTrue(excluded(g), "\(rule.id): glob '\(g)' is not excluded by system.app-caches")
                } else {
                    XCTAssertFalse(claimedByGeneric(g), "\(rule.id): '\(g)' would also match system.app-caches")
                }
                checked += 1
            }
            for p in rule.paths where p.raw.hasPrefix(cachesPrefix + "/") && rule.match.kind == .self {
                let name = String(p.raw.dropFirst(cachesPrefix.count + 1))
                guard !name.contains("/") else { continue }
                XCTAssertFalse(claimedByGeneric(name), "\(rule.id): \(name) would also match system.app-caches")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 10)
    }

    func testNoOverlapWithOtherBundledRulesOrT15() throws {
        let f = try FixtureHome()
        let rules = try allRules()
        let mine: Set<String> = ["dev-caches.json", file]
        var claims = PathClaimSet()
        func expand(_ r: ScannerRule) -> [String] {
            r.paths.compactMap { if case .path(let p) = $0.expand(in: f.env) { return p } else { return nil } }
        }
        let caches = f.abs("Library/Caches")
        // Rules in one file may share a `children` container; the container is claimed once. `$CACHES` is the
        // documented shared container (items are kept disjoint by testGenericCachesRuleExcludesEveryOtherCachesRule).
        var containers = Set<String>()
        func claimable(_ rule: ScannerRule) -> [String] {
            expand(rule).filter { p in
                if p == caches { return false }
                if rule.match.kind != .self { return containers.insert(p).inserted }
                return true
            }
        }
        for (rule, name) in rules where !mine.contains(name) {
            for p in claimable(rule) { _ = claims.claim(p) }   // other files overlap among themselves by design
        }
        for (rule, name) in rules where mine.contains(name) {
            for p in claimable(rule) {
                if let c = claims.claim(p) { XCTFail("\(rule.id): \(p) conflicts with \(c)") }
            }
        }
        // T15 (project-level build artifacts) is planned as name-based; none of ours may be one of those names.
        let t15 = ["DerivedData", "node_modules", ".venv", "target", ".next", ".gradle", "Pods"]
        for (rule, name) in rules where mine.contains(name) {
            for p in expand(rule) {
                let comps = p.split(separator: "/").map(String.init)
                XCTAssertFalse(comps.last.map(t15.contains) ?? false, "\(rule.id): \(p)")
                XCTAssertFalse(comps.contains("DerivedData") || comps.contains("node_modules"), "\(rule.id): \(p)")
            }
        }
    }

    func testBothFilesLoadCleanlyWithVietnamese() throws {
        let f = try FixtureHome()
        let result = RuleHarness.loadAllBundled(fixture: f)
        XCTAssertEqual(result.errors, [])
        let ids = result.allRules.map(\.rule.id)
        XCTAssertEqual(ids.count, Set(ids).count, "rule ids must be unique")
        for r in try allRules() where r.file == file {
            XCTAssertNotNil(r.0.localized["vi"]?.title, r.0.id)
            XCTAssertNotNil(r.0.localized["vi"]?.explanation, r.0.id)
        }
    }
}
