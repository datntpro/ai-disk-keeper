import XCTest
@testable import DiskKeeperCore
import protocol DiskKeeperCore.Scanner

final class ScanEngineScopeTests: XCTestCase {
    private var fixture: FixtureHome!
    private var rulesDir: TemporaryDirectory!

    override func setUpWithError() throws {
        fixture = try FixtureHome()
        rulesDir = try TemporaryDirectory()
    }

    private func run(scope: ScanScope, logs: [String] = ["a.log", "b.log"]) async throws -> [ScanItem] {
        let dir = fixture.abs("logs")
        for l in logs { try fixture.file("logs/" + l, bytes: 10) }
        let engine = try ScanEngine.makeDefault(
            environment: fixture.env, bundledRulesDirectory: rulesDir.url,
            extraScanners: [ExampleScanner(directory: dir)], maxConcurrentSizing: 2, scope: scope)
        let events = await EngineKit.collect(try await engine.scan())
        return EngineKit.items(events)
    }

    func testUnrestrictedKeepsAll() async throws {
        let items = try await run(scope: .unrestricted)
        XCTAssertEqual(items.map(\.displayName).sorted(), ["a.log", "b.log"])
    }

    func testExcludedFileDropsExactlyThatItem() async throws {
        let items = try await run(scope: ScanScope(excludedPaths: [fixture.abs("logs/a.log")]))
        XCTAssertEqual(items.map(\.displayName), ["b.log"])
    }

    func testExcludedParentDropsAll() async throws {
        let items = try await run(scope: ScanScope(excludedPaths: [fixture.abs("logs")]))
        XCTAssertTrue(items.isEmpty)
    }

    func testItemContainingExcludedPathIsDropped() async throws {
        let items = try await run(scope: ScanScope(excludedPaths: [fixture.abs("logs/a.log") + "/inner"]))
        XCTAssertEqual(items.map(\.displayName), ["b.log"])
    }

    func testCaseVariantMatches() async throws {
        let items = try await run(scope: ScanScope(excludedPaths: [fixture.abs("logs/A.LOG")]))
        XCTAssertEqual(items.map(\.displayName), ["b.log"])
    }

    func testDisabledToolIsDroppedAndNotScanned() async throws {
        try fixture.file(".t/cache/blob", bytes: 10)
        try fixture.file(".u/cache/blob", bytes: 10)
        try rulesDir.file("t.json", contents: Data(RuleFixtures.file(tool: "t", rules: [
            RuleFixtures.rule(id: "t.cache", paths: #"["~/.t/cache"]"#)]).utf8))
        try rulesDir.file("u.json", contents: Data(RuleFixtures.file(tool: "u", rules: [
            RuleFixtures.rule(id: "u.cache", paths: #"["~/.u/cache"]"#)]).utf8))
        func tools(_ scope: ScanScope) async throws -> [String] {
            let engine = try ScanEngine.makeDefault(environment: fixture.env, bundledRulesDirectory: rulesDir.url,
                                                    maxConcurrentSizing: 2, scope: scope)
            return EngineKit.items(await EngineKit.collect(try await engine.scan())).map(\.tool.rawValue).sorted()
        }
        let all = try await tools(.unrestricted)
        let some = try await tools(ScanScope(disabledTools: ["t"]))
        XCTAssertEqual(all, ["t", "u"])
        XCTAssertEqual(some, ["u"])
    }

    func testExcludedViaSymlinkedSpellingDropsItem() async throws {
        let dir = fixture.abs("logs")
        try fixture.file("logs/a.log", bytes: 10)
        try fixture.file("logs/b.log", bytes: 10)
        let link = try fixture.symlink("loglink", to: dir)
        let engine = try ScanEngine.makeDefault(
            environment: fixture.env, bundledRulesDirectory: rulesDir.url,
            extraScanners: [ExampleScanner(directory: dir)], maxConcurrentSizing: 2,
            scope: ScanScope(excludedPaths: [link + "/a.log"]))
        let items = EngineKit.items(await EngineKit.collect(try await engine.scan()))
        XCTAssertEqual(items.map(\.displayName), ["b.log"])
    }
}
