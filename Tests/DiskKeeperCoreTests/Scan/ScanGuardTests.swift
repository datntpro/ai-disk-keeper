import XCTest
@testable import DiskKeeperCore

final class ScanGuardTests: XCTestCase {
    private func denial(_ factory: RuleLoader.GuardFactory, patterns: [String] = [], _ path: String) throws -> GuardDenial? {
        try factory(patterns)(path)
    }

    func testLoaderFactoryMapsContainerReasonsToContainerOnly() throws {
        let f = try FixtureHome()
        let factory = ScanGuard.loaderFactory(environment: f.env)
        XCTAssertEqual(try denial(factory, f.abs(".claude/projects"))?.scope, .containerOnly)
        XCTAssertEqual(try denial(factory, f.abs(".ssh/x"))?.scope, .pathItself)
        XCTAssertNil(try denial(factory, f.abs(".cache/x")))
    }

    func testLoaderFactoryAppliesProtectPatterns() throws {
        let f = try FixtureHome()
        let factory = ScanGuard.loaderFactory(environment: f.env)
        let pattern = ProtectedPaths.escapeGlob(f.home) + "/.foo/**"
        XCTAssertEqual(try denial(factory, patterns: [pattern], f.abs(".foo/a"))?.scope, .pathItself)
        XCTAssertNil(try denial(factory, f.abs(".foo/a")))
    }

    func testLoaderFactoryThrowsOnInvalidRootSoLoaderFailsClosed() throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("rules/a.json", contents: Data(RuleFixtures.file(
            tool: "a", rules: [RuleFixtures.rule(id: "a.r", paths: #"["$TMPDIR/x"]"#)]).utf8))
        let env = PathEnvironment(home: "/", temporaryDirectory: tmp.path("T"))
        let result = RuleLoader(environment: env, bundledRulesDirectory: tmp.url.appendingPathComponent("rules"),
                                userRulesDirectory: nil, guardFactory: ScanGuard.loaderFactory(environment: env)).load()
        XCTAssertEqual(result.errors.map(\.kind), [.guardUnavailable])
        XCTAssertTrue(result.ruleSets.isEmpty)
    }

    func testHomeWithGlobCharactersStillProtected() throws {
        let tmp = try TemporaryDirectory()
        let env = PathEnvironment(home: tmp.path("a[1]"), temporaryDirectory: tmp.path("T"))
        try FileManager.default.createDirectory(atPath: env.home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: env.temporaryDirectory, withIntermediateDirectories: true)
        try tmp.file("rules/a.json", contents: Data(RuleFixtures.file(
            tool: "a", protect: #"["~/.foo"]"#, rules: [RuleFixtures.rule(id: "a.r", paths: #"["~/.bar/x"]"#)]).utf8))
        let load = RuleLoader(environment: env, bundledRulesDirectory: tmp.url.appendingPathComponent("rules"),
                              userRulesDirectory: nil, guardFactory: ScanGuard.loaderFactory(environment: env)).load()
        XCTAssertEqual(load.errors, [])
        let g = try ScanGuard(environment: env, protectPatterns: load.protectPatterns)
        XCTAssertFalse(g.check(env.home + "/.foo/x").isAllowed)
        XCTAssertFalse(g.check(env.home + "/.foo").isAllowed)
        XCTAssertTrue(g.check(env.home + "/.bar/x").isAllowed)
    }

    func testEscapeGlobIsTheSharedHelper() {
        let env = PathEnvironment(home: "/U/a[b]", temporaryDirectory: "/U/T")
        let t = try! PathTemplate("~/x", allowGlobs: true)
        XCTAssertEqual(t.expandPattern(in: env), .path("/U/a\\[b\\]/x"))
        XCTAssertEqual(t.expand(in: env), .path("/U/a[b]/x"))
    }
}
