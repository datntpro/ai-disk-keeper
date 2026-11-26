import XCTest
@testable import DiskKeeperCore

final class CareStagesTests: XCTestCase {
    func testScannerRunForwardsRealEngineEvents() async throws {
        let fx = try FixtureHome()
        try fx.file(".logs/a.log", bytes: 100)
        try fx.file(".logs/b.log", bytes: 200)
        let guardian = try ScanGuard(environment: fx.env, protectPatterns: [])
        let context = ScanContext(environment: fx.env, pathGuard: guardian, now: Date(), maxConcurrentSizing: 2)
        let spec = CareStages.rules { ScanEngine(context: context, scanners: [ExampleScanner(directory: fx.abs(".logs"))]) }
        XCTAssertEqual(spec.stage, .rules)
        XCTAssertEqual(spec.modules, [.aiTools, .worktrees, .modelsDocker, .systemJunk])

        let events = try await CareKit.run([spec])
        let items = events.compactMap { e -> ScanItem? in if case .item(.rules, let i) = e { i } else { nil } }
        XCTAssertEqual(items.map(\.displayName).sorted(), ["a.log", "b.log"])
        let raw = events.compactMap { e -> ScanEvent? in if case .scanEvent(.rules, let r) = e { r } else { nil } }
        XCTAssertTrue(raw.contains { if case .started = $0 { true } else { false } })
        XCTAssertTrue(raw.contains { if case .finished = $0 { true } else { false } })
        let report = try XCTUnwrap(CareKit.report(events))
        XCTAssertEqual(report.summaries[.systemJunk]?.itemCount, 2)
        XCTAssertEqual(report.summaries[.systemJunk]?.safeBytes, report.totals.safeBytes)
    }

    func testScannerRunThatCannotMakeAnEngineFailsTheStageOnly() async throws {
        let spec = CareStages.scannerRun(.rules, modules: [.aiTools]) { throw CareTestFailure() }
        let events = try await CareKit.run([spec, FakeStage.spec(.apps)])
        XCTAssertEqual(CareKit.trace(events), ["start:rules", "fail:rules", "start:apps", "finish:apps", "finished"])
    }

    func testIndexStageEmitsTreeArtifactThatFeedsNextStage() async throws {
        let fx = try FixtureHome()
        try fx.file("Documents/x.bin", bytes: 10)
        let events = try await CareKit.run([CareStages.index { try await IndexTest.index(fx) }])
        XCTAssertTrue(events.contains { if case .artifact(.tree) = $0 { true } else { false } })
    }

    func testDuplicatesStageListsMembersAndEmitsArtifact() async throws {
        let fx = try FixtureHome()
        let c1 = DupFix.data(seed: 7, count: DupFix.mb)
        try DupFix.write(fx.abs("docs/a"), c1)
        try DupFix.write(fx.abs("docs/b"), c1)
        let guardian = try ScanGuard(environment: fx.env, protectPatterns: [])
        let events = try await CareKit.run([
            CareStages.index { try await IndexTest.index(fx) },
            CareStages.duplicates(options: DupFix.options(fx), keeper: .oldest, guardProvider: { guardian }, userID: getuid()),
        ])
        let items = events.compactMap { e -> ScanItem? in if case .item(.duplicates, let i) = e { i } else { nil } }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.filter { $0.flags.contains(.suggestedKeeper) }.count, 1)
        XCTAssertTrue(events.contains { if case .artifact(.duplicates(let r)) = $0 { r.groups.count == 1 } else { false } })
        let report = try XCTUnwrap(CareKit.report(events))
        XCTAssertEqual(report.summaries[.duplicates]?.itemCount, 1, "the keeper is not counted")
    }

    func testAppsStageListsOnlyUninstallableBundlesAndEmitsInventory() async throws {
        let fx = try FixtureHome()
        let guardian = try ScanGuard(environment: fx.env, protectPatterns: [])
        let context = ScanContext(environment: fx.env, pathGuard: guardian, now: Date(), maxConcurrentSizing: 2)
        let user = InstalledApp(path: fx.abs("Applications/Mine.app"), bundleID: "com.example.mine", name: "Mine",
                                location: .userApplications, source: .unsigned, ownerUID: getuid(), isSymlink: false,
                                sizeAllocated: 900, sizeLogical: 900, fileCount: 3, viewOnlyReason: nil)
        let apple = InstalledApp(path: "/Applications/Safari.app", bundleID: "com.apple.Safari", name: "Safari",
                                 location: .applications, source: .apple, ownerUID: 0, isSymlink: false,
                                 sizeAllocated: 5_000, sizeLogical: 5_000, fileCount: 9, viewOnlyReason: .apple)
        let inventory = AppInventory(apps: [user, apple], warnings: [], scannedRoots: [])
        let spec = CareStages.apps(inventory: { inventory },
                                   leftovers: { _ in ScanEngine(context: context, scanners: []) })
        let events = try await CareKit.run([spec])
        let items: [ScanItem] = events.compactMap { e in if case .item(.apps, let i) = e { return i } else { return nil } }
        XCTAssertEqual(items.map { $0.displayName }, ["Mine"])
        XCTAssertEqual(items.first?.category, ItemCategory.application)
        XCTAssertTrue(events.contains { if case .artifact(.apps(let i)) = $0 { i.apps.count == 2 } else { false } })
        XCTAssertEqual(CareKit.report(events)?.summaries[.apps]?.reviewBytes, 900)
    }
}
