import XCTest
@testable import DiskKeeperCore

final class AppInventoryScannerTests: XCTestCase {
    private var fx: FixtureHome!
    private var roots: AppRoots!
    private var apps: String { roots.applications }

    override func setUpWithError() throws {
        fx = try FixtureHome()
        roots = AppRoots(applications: fx.tmp.path("Applications"), userApplications: fx.home + "/Applications",
                         library: fx.home + "/Library")
        try FileManager.default.createDirectory(atPath: roots.applications, withIntermediateDirectories: true)
    }

    private func scanner(sigs: FakeSignatures = FakeSignatures(), running: FakeRunning = FakeRunning(),
                         userID: uid_t = getuid(), usage: FakeUsage = FakeUsage(),
                         realPath: @escaping @Sendable (String) -> String? = { AppBundleReader.resolvedPath($0) }) -> AppInventoryScanner {
        AppInventoryScanner(roots: roots, signatures: sigs, usage: usage, runningApps: running, userID: userID,
                            sizer: FileSizer(), maxConcurrentSizing: 2, realPath: realPath)
    }

    func testViewOnlyReasons() async throws {
        try AppFixtures.makeApp(at: apps + "/Plain.app", bundleID: "com.t.plain", name: "Plain")
        try AppFixtures.makeApp(at: apps + "/Apple.app", bundleID: "com.apple.thing", name: "AppleThing")
        try AppFixtures.makeApp(at: apps + "/Utilities/Util.app", bundleID: "com.t.util", name: "Util")
        try AppFixtures.makeApp(at: apps + "/Vendor/Vend.app", bundleID: "com.t.vend", name: "Vend")
        let real = try AppFixtures.makeApp(at: fx.tmp.path("elsewhere/Linked.app"), bundleID: "com.t.linked", name: "Linked")
        try fx.tmp.symlink("Applications/Linked.app", to: real)
        let sysReal = try AppFixtures.makeApp(at: fx.tmp.path("elsewhere/Sys.app"), bundleID: "com.t.sys", name: "Sys")
        try fx.tmp.symlink("Applications/Sys.app", to: sysReal)
        let sysPath = apps + "/Sys.app"
        let sigs = FakeSignatures(sources: ["Apple.app": .apple])
        let inv = try await scanner(sigs: sigs, realPath: { $0 == sysPath ? "/System/Cryptexes/Sys.app" : AppBundleReader.resolvedPath($0) }).inventory()
        let reasons = Dictionary(uniqueKeysWithValues: inv.apps.map { ($0.bundleID, $0.viewOnlyReason) })
        XCTAssertEqual(reasons["com.t.plain"] ?? .some(.apple), nil)
        XCTAssertEqual(reasons["com.apple.thing"], .some(.apple))
        XCTAssertEqual(reasons["com.t.util"], .some(.notTopLevel))
        XCTAssertEqual(reasons["com.t.vend"], .some(.notTopLevel))
        XCTAssertEqual(reasons["com.t.linked"], .some(.symlink))
        XCTAssertEqual(reasons["com.t.sys"], .some(.systemVolume))
        XCTAssertEqual(inv.apps.first { $0.bundleID == "com.t.util" }?.location, .applicationsUtilities)
        XCTAssertEqual(inv.apps.first { $0.bundleID == "com.t.vend" }?.location, .applicationsNested)
    }

    func testNotOwnedByUser() async throws {
        try AppFixtures.makeApp(at: apps + "/Plain.app", bundleID: "com.t.plain")
        let inv = try await scanner(userID: getuid() + 1).inventory()
        XCTAssertEqual(inv.apps.first?.viewOnlyReason, .notOwnedByUser)
    }

    func testAppleAndSystemAppsNeverActionable() async throws {
        try AppFixtures.makeApp(at: apps + "/Apple.app", bundleID: "com.apple.thing")
        try AppFixtures.makeApp(at: apps + "/Utilities/U.app", bundleID: "com.t.u")
        let inv = try await scanner(sigs: FakeSignatures(sources: ["Apple.app": .apple]), userID: getuid() + 1).inventory()
        XCTAssertEqual(inv.apps.count, 2)
        for app in inv.apps {
            XCTAssertNotNil(app.viewOnlyReason)
            let item = app.makeScanItem()
            XCTAssertEqual(item.cleanupMethod, .none)
            XCTAssertFalse(item.isSelectable)
        }
    }

    func testActionableAppUsesTrashApplication() async throws {
        try AppFixtures.makeApp(at: apps + "/Plain.app", bundleID: "com.t.plain", name: "Plain")
        let inv = try await scanner().inventory()
        let item = try XCTUnwrap(inv.apps.first).makeScanItem()
        XCTAssertEqual(item.cleanupMethod, .trashApplication(bundleID: "com.t.plain"))
        XCTAssertEqual(item.tier, .review)
        XCTAssertTrue(item.isSelectable)
        XCTAssertFalse(item.isBulkSelectable)
        XCTAssertEqual(item.groupID, "app:com.t.plain")
        XCTAssertEqual(item.category, .application)
        XCTAssertEqual(item.tool, .apps)
        XCTAssertEqual(item.ruleID, "apps.bundle")
        XCTAssertEqual(item.requiresAppQuit, "com.t.plain")
    }

    func testSkipsBadBundlesWithWarnings() async throws {
        try AppFixtures.makeApp(at: apps + "/NoID.app", bundleID: nil)
        try AppFixtures.makeApp(at: apps + "/NoPlist.app", bundleID: nil, omitPlist: true)
        try AppFixtures.makeApp(at: apps + "/Bad.app", bundleID: nil, plist: Data("junk".utf8))
        try Data().write(to: URL(fileURLWithPath: apps + "/PlainFile.app"))
        try AppFixtures.makeApp(at: apps + "/Upper.APP", bundleID: "com.t.upper")
        try AppFixtures.makeApp(at: apps + "/Bin.app", bundleID: "com.t.bin", binary: true)
        let inv = try await scanner().inventory()
        XCTAssertEqual(Set(inv.apps.map(\.bundleID)), ["com.t.upper", "com.t.bin"])
        XCTAssertEqual(inv.warnings.count, 3)
        XCTAssertEqual(Set(inv.warnings.compactMap(\.path).map { ($0 as NSString).lastPathComponent }),
                       ["NoID.app", "NoPlist.app", "Bad.app"])
    }

    func testSourcesRunningAndUsage() async throws {
        try AppFixtures.makeApp(at: apps + "/Store.app", bundleID: "com.t.store", receipt: true)
        try AppFixtures.makeApp(at: apps + "/Run.app", bundleID: "com.t.run")
        let used = Date(timeIntervalSince1970: 1_700_000_000)
        let inv = try await scanner(sigs: FakeSignatures(sources: ["Run.app": .unsigned]),
                                    running: FakeRunning(running: ["com.t.run"]),
                                    usage: FakeUsage(dates: ["Run.app": used])).inventory()
        let store = try XCTUnwrap(inv.apps.first { $0.bundleID == "com.t.store" })
        XCTAssertEqual(store.source, .appStore(teamID: "TEAM123456"))
        let run = try XCTUnwrap(inv.apps.first { $0.bundleID == "com.t.run" })
        XCTAssertEqual(run.isRunning, true)
        XCTAssertEqual(run.lastUsed, used)
        XCTAssertEqual(run.source, .unsigned)
        XCTAssertNotNil(run.makeScanItem().cleanupMethod.isActionable ? 1 : nil)  // still offered; run state is checked at plan
    }

    func testSizesMatchFileSizerSortedAndInsideFixture() async throws {
        try AppFixtures.makeApp(at: apps + "/Small.app", bundleID: "com.t.small", name: "Small", payload: 10)
        try AppFixtures.makeApp(at: apps + "/Big.app", bundleID: "com.t.big", name: "Big", payload: 300_000)
        try AppFixtures.makeApp(at: apps + "/Alpha.app", bundleID: "com.t.alpha", name: "Alpha", payload: 10)
        let inv = try await scanner().inventory()
        for app in inv.apps {
            XCTAssertTrue(app.path.hasPrefix(fx.tmp.url.path))
            let report = try FileSizer().sizeBlocking(of: URL(fileURLWithPath: app.path))
            XCTAssertEqual(app.sizeAllocated, report.allocatedBytes)
            XCTAssertEqual(app.sizeLogical, report.logicalBytes)
            XCTAssertEqual(app.fileCount, report.fileCount)
        }
        XCTAssertEqual(inv.apps.map(\.name).first, "Big")
        XCTAssertEqual(inv.apps.map(\.name).suffix(2), ["Alpha", "Small"])   // equal size: by name
    }

    func testSymlinkedAppIsNotSizedThroughTheLink() async throws {
        let real = try AppFixtures.makeApp(at: fx.tmp.path("elsewhere/Linked.app"), bundleID: "com.t.linked", payload: 500_000)
        try fx.tmp.symlink("Applications/Linked.app", to: real)
        let inv = try await scanner().inventory()
        let app = try XCTUnwrap(inv.apps.first)
        XCTAssertTrue(app.isSymlink)
        XCTAssertLessThan(app.sizeLogical, 1000)
        XCTAssertEqual(app.makeScanItem().flags, [.symlink])
    }

    func testInventoryIsReadOnly() async throws {
        try AppFixtures.makeApp(at: apps + "/Plain.app", bundleID: "com.t.plain")
        let before = try fx.snapshot()
        _ = try await scanner().inventory()
        XCTAssertEqual(try fx.snapshot(), before)
    }
}
