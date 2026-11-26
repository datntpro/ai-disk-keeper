import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

final class DuplicateScannerTests: XCTestCase {
    private actor Box {
        var items: [ScanItem] = []
        var warnings: [ScanWarning] = []
        func add(_ i: ScanItem) { items.append(i) }
        func add(_ w: ScanWarning) { warnings.append(w) }
    }

    private func scan(_ fx: FixtureHome, options: DuplicateOptions? = nil) async throws -> (items: [ScanItem], warnings: [ScanWarning]) {
        let guardian = try ScanGuard(environment: fx.env, protectPatterns: [])
        let context = ScanContext(environment: fx.env, pathGuard: guardian, now: Date(), userID: getuid())
        let box = Box()
        let sink = ScanSink(item: { await box.add($0) }, warning: { await box.add($0) }, progress: { _ in })
        let scanner = DuplicateScanner(options: options ?? DupFix.options(fx), tree: { try await IndexTest.index(fx) })
        XCTAssertEqual(scanner.id, "duplicates")
        try await scanner.scan(context: context, sink: sink)
        return (await box.items.sorted { $0.path < $1.path }, await box.warnings)
    }

    func testItemsPerMemberWithOneKeeperEach() async throws {
        let fx = try FixtureHome()
        let c1 = DupFix.data(seed: 1, count: DupFix.mb), c2 = DupFix.data(seed: 2, count: 2_000_000)
        let a = try DupFix.write(fx.abs("docs/a"), c1)
        try DupFix.write(fx.abs("docs/b"), c1)
        try DupFix.write(fx.abs("docs/c"), c1)
        try DupFix.write(fx.abs("docs/x"), c2); try DupFix.write(fx.abs("docs/y"), c2)
        try DupFix.setBirthTime(a, Date(timeIntervalSinceNow: -9000))

        let (items, warnings) = try await scan(fx)
        XCTAssertEqual(items.count, 5)
        XCTAssertTrue(warnings.isEmpty)
        let byGroup = Dictionary(grouping: items, by: { $0.groupID ?? "" })
        XCTAssertEqual(byGroup.count, 2)
        for (gid, members) in byGroup {
            XCTAssertTrue(gid.hasPrefix("dup:"))
            XCTAssertEqual(members.filter { $0.flags.contains(.suggestedKeeper) }.count, 1)
        }
        for i in items {
            XCTAssertEqual(i.tier, .review)
            XCTAssertEqual(i.category, .duplicate)
            XCTAssertEqual(i.tool, .files)
            XCTAssertEqual(i.ruleID, "duplicates.copy")
            XCTAssertEqual(i.fileCount, 1)
            XCTAssertTrue(i.path.hasPrefix(fx.home + "/"), "outside the fixture: \(i.path)")
        }
        let keeper = try XCTUnwrap(items.first { $0.path == a })
        XCTAssertTrue(keeper.flags.contains(.suggestedKeeper))
        XCTAssertTrue(keeper.explanation.contains("Suggested to keep: oldest copy"))
        XCTAssertTrue(keeper.explanation.contains("2 other files"))
        let other = try XCTUnwrap(items.first { $0.path == fx.abs("docs/b") })
        XCTAssertTrue(other.explanation.contains("Identical to a"))
        XCTAssertTrue(other.explanation.contains(a))
    }

    func testFullCloneMemberIsReportOnly() async throws {
        let fx = try FixtureHome()
        let content = DupFix.data(seed: 3, count: DupFix.mb)
        let a = try DupFix.write(fx.abs("a"), content)
        try DupFix.write(fx.abs("b"), content)
        let clone = fx.abs("c")
        try DupFix.clone(a, clone)
        try DupFix.setBirthTime(a, Date(timeIntervalSinceNow: -9000))
        let (items, _) = try await scan(fx)
        let c = try XCTUnwrap(items.first { $0.path == clone })
        XCTAssertEqual(c.cleanupMethod, .none)
        XCTAssertTrue(c.flags.contains(.sharedStorage))
        XCTAssertFalse(c.isSelectable)
        let b = try XCTUnwrap(items.first { $0.path == fx.abs("b") })
        XCTAssertEqual(b.cleanupMethod, .trash)
        XCTAssertFalse(b.flags.contains(.sharedStorage))
    }

    func testGuardDeniedMembersAreDroppedAndTinyGroupsSkipped() async throws {
        let fx = try FixtureHome()
        let content = DupFix.data(seed: 4, count: DupFix.mb)
        try DupFix.write(fx.abs("docs/a"), content)
        try DupFix.write(fx.abs("docs/b"), content)
        let guardian = try ScanGuard(environment: fx.env, protectPatterns: [ProtectedPaths.escapeGlob(fx.abs("docs/b"))])
        let context = ScanContext(environment: fx.env, pathGuard: guardian, now: Date(), userID: getuid())
        let box = Box()
        let sink = ScanSink(item: { await box.add($0) }, warning: { await box.add($0) }, progress: { _ in })
        try await DuplicateScanner(options: DupFix.options(fx), tree: { try await IndexTest.index(fx) })
            .scan(context: context, sink: sink)
        let items = await box.items
        XCTAssertTrue(items.isEmpty, "one member left: the whole group is skipped")
    }

    func testDirectReportMatchesFinder() async throws {
        let fx = try FixtureHome()
        let content = DupFix.data(seed: 5, count: DupFix.mb)
        try DupFix.write(fx.abs("a"), content); try DupFix.write(fx.abs("b"), content)
        let scanner = DuplicateScanner(options: DupFix.options(fx), tree: { try await IndexTest.index(fx) })
        let report = try await scanner.report(tree: try await IndexTest.index(fx))
        XCTAssertEqual(report.groups.count, 1)
    }
}
