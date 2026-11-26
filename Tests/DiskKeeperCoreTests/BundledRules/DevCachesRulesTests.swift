import XCTest
@testable import DiskKeeperCore

final class DevCachesRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
    private let file = "dev-caches.json"

    private func run(_ f: FixtureHome) async throws -> HarnessResult {
        let r = try await RuleHarness.run(bundledFile: file, fixture: f, now: now)
        XCTAssertEqual(r.loadErrors, [])
        let root = f.tmp.url.path
        for i in r.items where !i.path.hasPrefix(root + "/") { XCTFail("item outside the fixture: \(i.path)") }
        return r
    }

    /// A directory holding one file, both last modified `days` ago.
    @discardableResult
    private func make(_ f: FixtureHome, _ rel: String, days: Double) throws -> String {
        try f.file(rel + "/payload.bin", bytes: 4096, modified: ago(days: days))
        return try f.dir(rel, modified: ago(days: days))
    }

    /// (rule id, relative default path, expected tier when old)
    private let selfRules: [(String, String, RiskTier)] = [
        ("dev-caches.yarn", "Library/Caches/Yarn", .review),
        ("dev-caches.yarn-berry", ".yarn/berry/cache", .review),
        ("dev-caches.cargo-registry", ".cargo/registry/cache", .review),
        ("dev-caches.cargo-registry", ".cargo/registry/src", .review),
        ("dev-caches.cargo-git", ".cargo/git/db", .review),
        ("dev-caches.cargo-git", ".cargo/git/checkouts", .review),
        ("dev-caches.go-build", "Library/Caches/go-build", .safe),
        ("dev-caches.go-mod", "go/pkg/mod", .review),
        ("dev-caches.gradle", ".gradle/caches", .review),
        ("dev-caches.cocoapods", "Library/Caches/CocoaPods", .review),
        ("dev-caches.swiftpm", "Library/Caches/org.swift.swiftpm", .review),
        ("dev-caches.homebrew", "Library/Caches/Homebrew", .review),
        ("dev-caches.simulator-caches", "Library/Developer/CoreSimulator/Caches", .safe),
        ("dev-caches.xcode-previews", "Library/Developer/Xcode/UserData/Previews", .safe),
    ]

    func testEverySelfRuleOldAndFresh() async throws {
        for (id, rel, tier) in selfRules {
            let old = try FixtureHome()
            try make(old, rel, days: 40)
            let r = try await run(old)
            let item = try XCTUnwrap(r.item(old.abs(rel)), "\(id) \(rel)")
            XCTAssertEqual(item.ruleID, id)
            XCTAssertEqual(item.tier, tier, id)
            XCTAssertEqual(item.tool.rawValue, "dev-caches")
            XCTAssertEqual(item.category, .systemJunk)
            XCTAssertEqual(r.items.count, 1, "\(id): \(r.paths)")
            XCTAssertEqual(r.warnings.count, 0)

            let fresh = try FixtureHome()
            try make(fresh, rel, days: 0.5)
            let freshResult = try await run(fresh)
            XCTAssertEqual(freshResult.tier(fresh.abs(rel)), .keep, "\(id) fresh")
        }
    }

    func testAbsentGivesNoItemsOrWarnings() async throws {
        let f = try FixtureHome()
        let r = try await run(f)
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertTrue(r.warnings.isEmpty)
    }

    func testEnvOverridesAreHonoured() async throws {
        let cases: [(String, String, String)] = [   // variable, id, default relative path
            ("CARGO_HOME", "dev-caches.cargo-registry", ".cargo/registry/cache"),
            ("GOCACHE", "dev-caches.go-build", "Library/Caches/go-build"),
            ("GOMODCACHE", "dev-caches.go-mod", "go/pkg/mod"),
            ("GRADLE_USER_HOME", "dev-caches.gradle", ".gradle/caches"),
            ("YARN_CACHE_FOLDER", "dev-caches.yarn", "Library/Caches/Yarn"),
            ("HOMEBREW_CACHE", "dev-caches.homebrew", "Library/Caches/Homebrew"),
        ]
        for (variable, id, defaultRel) in cases {
            let f = try FixtureHome()
            let base = f.abs("elsewhere/\(variable)")
            f.env = PathEnvironment(home: f.home, temporaryDirectory: f.tempDir, variables: [variable: base])
            let custom: String
            switch variable {
            case "CARGO_HOME": custom = "registry/cache"
            case "GRADLE_USER_HOME": custom = "caches"
            default: custom = ""
            }
            let rel = custom.isEmpty ? "elsewhere/\(variable)" : "elsewhere/\(variable)/\(custom)"
            try make(f, rel, days: 40)
            try make(f, defaultRel, days: 40)   // present, but must not be used
            let r = try await run(f)
            XCTAssertEqual(r.items.filter { $0.ruleID == id }.map(\.path), [f.abs(rel)], variable)
            XCTAssertNil(r.item(f.abs(defaultRel)), "\(variable): default path must not appear")
        }
    }

    func testArchivesNeverSafe() async throws {
        let f = try FixtureHome()
        let a = "Library/Developer/Xcode/Archives/2023-01-01/App 1-1-23.xcarchive"
        try make(f, a, days: 1100)
        try f.dir("Library/Developer/Xcode/Archives/2023-01-01", modified: ago(days: 1100))
        try make(f, "Library/Developer/Xcode/Archives/2023-01-01/Notes.txt.d", days: 1100)
        let r = try await run(f)
        XCTAssertEqual(r.tier(f.abs(a)), .review)
        XCTAssertEqual(r.items.map(\.path), [f.abs(a)])
        XCTAssertEqual(r.items.first?.ruleID, "dev-caches.xcode-archives")
    }

    func testDeviceSupportSafeAfter180Days() async throws {
        let f = try FixtureHome()
        let base = "Library/Developer/Xcode/iOS DeviceSupport"
        try make(f, "\(base)/17.0 (21A329)", days: 200)
        try make(f, "\(base)/17.4 (21E219)", days: 100)
        try make(f, "\(base)/18.0 (22A3354)", days: 0.5)
        try make(f, "Library/Developer/Xcode/watchOS DeviceSupport/10.0", days: 200)
        try make(f, "Library/Developer/Xcode/tvOS DeviceSupport/17.0", days: 200)
        try make(f, "Library/Developer/Xcode/visionOS DeviceSupport/1.0", days: 200)
        try f.file("\(base)/.DS_Store", modified: ago(days: 200))
        let r = try await run(f)
        XCTAssertEqual(r.tier(f.abs("\(base)/17.0 (21A329)")), .safe)
        XCTAssertEqual(r.tier(f.abs("\(base)/17.4 (21E219)")), .review)
        XCTAssertEqual(r.tier(f.abs("\(base)/18.0 (22A3354)")), .keep)
        XCTAssertEqual(r.items.count, 6)
        XCTAssertNil(r.item(f.abs("\(base)/.DS_Store")))
        for i in r.items { XCTAssertEqual(i.requiresAppQuit, "com.apple.dt.Xcode", i.path) }
    }

    func testAppQuitOnlyWhereTheAppCanHoldFiles() async throws {
        let f = try FixtureHome()
        try make(f, "Library/Developer/CoreSimulator/Caches", days: 40)
        try make(f, "Library/Developer/Xcode/UserData/Previews", days: 40)
        try make(f, "go/pkg/mod", days: 40)
        let r = try await run(f)
        XCTAssertEqual(r.item(f.abs("Library/Developer/CoreSimulator/Caches"))?.requiresAppQuit, "com.apple.iphonesimulator")
        XCTAssertEqual(r.item(f.abs("Library/Developer/Xcode/UserData/Previews"))?.requiresAppQuit, "com.apple.dt.Xcode")
        XCTAssertNil(r.item(f.abs("go/pkg/mod"))?.requiresAppQuit)
    }

    func testGradleWrapperChildrenOnly() async throws {
        let f = try FixtureHome()
        try make(f, ".gradle/wrapper/dists/gradle-8.5-bin", days: 40)
        try f.file(".gradle/wrapper/dists/stray.txt", modified: ago(days: 40))
        let r = try await run(f)
        XCTAssertEqual(r.items.filter { $0.ruleID == "dev-caches.gradle-wrapper" }.map(\.path),
                       [f.abs(".gradle/wrapper/dists/gradle-8.5-bin")])
    }

    func testGoModReadOnlyTreeStillSized() async throws {
        let f = try FixtureHome()
        let root = try make(f, "go/pkg/mod/github.com/x/y@v1.0.0", days: 40)
        try f.dir("go/pkg/mod", modified: ago(days: 40))
        let mod = f.abs("go/pkg/mod")
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "a-w", mod]
        try chmod.run(); chmod.waitUntilExit()
        defer {
            let undo = Process()
            undo.executableURL = URL(fileURLWithPath: "/bin/chmod")
            undo.arguments = ["-R", "u+w", mod]
            try? undo.run(); undo.waitUntilExit()
        }
        _ = root
        let r = try await run(f)
        let item = try XCTUnwrap(r.item(mod))
        XCTAssertGreaterThanOrEqual(item.sizeAllocated, 4096)
        XCTAssertEqual(item.fileCount, 1)
        XCTAssertFalse(item.flags.contains(.sizeIncomplete))
    }

    func testProtectedFilesNeverItems() async throws {
        let f = try FixtureHome()
        for p in [".cargo/credentials.toml", ".cargo/config.toml", ".gradle/gradle.properties", ".gradle/init.d/x.gradle",
                  ".yarnrc", ".yarnrc.yml"] {
            try f.file(p, modified: ago(days: 400))
        }
        try make(f, ".cargo/registry/cache", days: 40)
        try make(f, ".gradle/caches", days: 40)
        let r = try await run(f)
        for i in r.items { XCTAssertFalse(i.path.contains("credentials") || i.path.hasSuffix("gradle.properties")
                                          || i.path.contains("init.d") || i.path.contains(".yarnrc"), i.path) }
        let loaded = RuleHarness.loadAllBundled(fixture: f)
        XCTAssertEqual(loaded.errors, [])
        let guardian = try ScanGuard(environment: f.env, protectPatterns: loaded.protectPatterns)
        for p in [".cargo/credentials.toml", ".cargo/config.toml", ".gradle/gradle.properties", ".gradle/init.d/x.gradle",
                  ".yarnrc", ".yarnrc.yml"] {
            if case .allowed = guardian.check(f.abs(p)) { XCTFail("\(p) is not protected") }
        }
    }

    func testCargoHomeOverrideKeepsCredentialsProtected() throws {
        let f = try FixtureHome()
        let base = f.abs("elsewhere/cargo")
        f.env = PathEnvironment(home: f.home, temporaryDirectory: f.tempDir, variables: ["CARGO_HOME": base])
        let loaded = RuleHarness.loadAllBundled(fixture: f)
        let guardian = try ScanGuard(environment: f.env, protectPatterns: loaded.protectPatterns)
        if case .allowed = guardian.check(base + "/credentials.toml") { XCTFail("credentials under CARGO_HOME not protected") }
    }

    func testEveryRuleHasVietnameseAndToolDocs() throws {
        let dir = try XCTUnwrap(CoreResources.rulesDirectoryURL)
        let f = try JSONDecoder().decode(RuleFile.self, from: Data(contentsOf: dir.appendingPathComponent(file)))
        XCTAssertEqual(f.rules.count, 15)
        XCTAssertNotNil(f.tool.docs)
        for r in f.rules {
            XCTAssertNotNil(r.localized["vi"]?.title, r.id)
            XCTAssertNotNil(r.localized["vi"]?.explanation, r.id)
            XCTAssertEqual(r.category, .systemJunk)
        }
    }
}
