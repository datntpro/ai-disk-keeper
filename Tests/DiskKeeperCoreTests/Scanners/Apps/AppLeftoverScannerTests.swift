import XCTest
@testable import DiskKeeperCore

final class AppLeftoverScannerTests: XCTestCase {
    private var fx: FixtureHome!
    private var lib: String { fx.home + "/Library" }
    private let now = Date()
    private var restore: [String] = []

    override func setUpWithError() throws { fx = try FixtureHome() }
    override func tearDown() {
        for p in restore { chmod(p, 0o755) }
        restore = []
    }

    private func context(protect: [String] = [], userID: uid_t = getuid()) throws -> ScanContext {
        ScanContext(environment: fx.env, pathGuard: try ScanGuard(environment: fx.env, protectPatterns: protect),
                    now: now, userID: userID)
    }

    private func app(_ id: String, _ name: String, team: String? = "TEAM123456") -> InstalledApp {
        AppFixtures.app(id, name: name, team: team)
    }

    private func run(apps: [InstalledApp], lookup: FakeLookup = FakeLookup(), protect: [String] = [],
                     userID: uid_t = getuid()) async throws -> SnapshotBox {
        let box = SnapshotBox()
        let inv = AppInventory(apps: apps, warnings: [], scannedRoots: [])
        let scanner = AppLeftoverScanner(inventory: { inv }, library: lib, lookup: lookup)
        try await scanner.scan(context: try context(protect: protect, userID: userID), sink: box.sink)
        return box
    }

    private func old(_ rel: String) throws {
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90 * 86_400)],
                                              ofItemAtPath: fx.abs(rel))
    }

    func testExactNameOrphanAndShared() async throws {
        try fx.file("Library/Containers/com.foo.app/Data/x", bytes: 4000)
        try fx.file("Library/Application Support/Foo/y", bytes: 100)
        try fx.file("Library/Group Containers/TEAM123456.group.shared/z", bytes: 100)
        try fx.file("Library/Containers/com.gone.tool/Data/o", bytes: 100)
        for p in ["Library/Containers/com.gone.tool/Data/o", "Library/Containers/com.gone.tool/Data",
                  "Library/Containers/com.gone.tool"] { try old(p) }
        let apps = [app("com.foo.app", "Foo"), app("com.foo.other", "Other")]
        let box = try await run(apps: apps, lookup: FakeLookup(answers: ["com.gone.tool": false]))
        let byName = Dictionary(uniqueKeysWithValues: box.items.map { (($0.path as NSString).lastPathComponent, $0) })

        let exact = try XCTUnwrap(byName["com.foo.app"])
        XCTAssertEqual(exact.ruleID, "apps.leftover.exact")
        XCTAssertEqual(exact.groupID, "app:com.foo.app")
        XCTAssertEqual(exact.requiresAppQuit, "com.foo.app")
        XCTAssertEqual(exact.category, .appLeftover)
        XCTAssertEqual(exact.tier, .review)
        XCTAssertEqual(exact.cleanupMethod, .trash)
        XCTAssertFalse(exact.isBulkSelectable)
        XCTAssertGreaterThan(exact.sizeAllocated, 0)
        XCTAssertTrue(exact.displayName.hasPrefix("Foo · Containers/"))

        XCTAssertEqual(byName["Foo"]?.ruleID, "apps.leftover.name")
        XCTAssertEqual(byName["Foo"]?.groupID, "app:com.foo.app")

        let shared = try XCTUnwrap(byName["TEAM123456.group.shared"])
        XCTAssertEqual(shared.ruleID, "apps.leftover.name")
        XCTAssertNil(shared.groupID)
        XCTAssertNil(shared.requiresAppQuit)
        XCTAssertTrue(shared.explanation.contains("Used by Foo and Other"))

        let orphan = try XCTUnwrap(byName["com.gone.tool"])
        XCTAssertEqual(orphan.ruleID, "apps.leftover.orphan")
        XCTAssertNil(orphan.groupID)
        XCTAssertNil(orphan.requiresAppQuit)

        for i in box.items { XCTAssertTrue(i.path.hasPrefix(lib + "/"), i.path) }
    }

    func testOrphanWithRecentContentIsNotEmitted() async throws {
        try fx.file("Library/Containers/com.gone.tool/Data/fresh", bytes: 100)   // fresh file inside
        try old("Library/Containers/com.gone.tool")
        let box = try await run(apps: [], lookup: FakeLookup(answers: ["com.gone.tool": false]))
        XCTAssertTrue(box.items.isEmpty)
    }

    func testProtectedEntriesAreDropped() async throws {
        try fx.file("Library/Containers/com.foo.app/x", bytes: 10)
        try fx.file("Library/Application Support/Foo/y", bytes: 10)
        let protect = [ProtectedPaths.escapeGlob(lib) + "/Application Support/Foo"]
        let box = try await run(apps: [app("com.foo.app", "Foo")], protect: protect)
        XCTAssertEqual(box.items.map { ($0.path as NSString).lastPathComponent }, ["com.foo.app"])
    }

    func testUnreadableGroupContainersGivesOneWarning() async throws {
        try XCTSkipIf(getuid() == 0, "root ignores chmod")
        try fx.file("Library/Group Containers/TEAM123456.group.x/z")
        let dir = fx.abs("Library/Group Containers")
        chmod(dir, 0o000)
        restore.append(dir)
        let box = try await run(apps: [app("com.foo.app", "Foo")])
        XCTAssertEqual(box.warnings.filter { $0.path == dir }.count, 1)
        XCTAssertTrue(box.items.isEmpty)
    }

    func testCancellationPropagates() async throws {
        for i in 0..<20 { try fx.file("Library/Caches/com.foo.app/f\(i)", bytes: 10) }
        let inv = AppInventory(apps: [app("com.foo.app", "Foo")], warnings: [], scannedRoots: [])
        let scanner = AppLeftoverScanner(inventory: { try await Task.sleep(nanoseconds: 5_000_000_000); return inv },
                                         library: lib, lookup: FakeLookup())
        let ctx = try context()
        let box = SnapshotBox()
        let task = Task { try await scanner.scan(context: ctx, sink: box.sink) }
        task.cancel()
        do { try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
    }

    func testScanIsReadOnly() async throws {
        try fx.file("Library/Containers/com.foo.app/x", bytes: 10)
        try fx.file("Library/Application Support/Foo/y", bytes: 10)
        let before = try fx.snapshot()
        _ = try await run(apps: [app("com.foo.app", "Foo")])
        XCTAssertEqual(try fx.snapshot(), before)
    }

    // N4
    func testSymlinkedEntriesAndLocationsAreIgnored() async throws {
        let outside = fx.tmp.path("outside")
        try FileManager.default.createDirectory(atPath: outside + "/com.foo.app", withIntermediateDirectories: true)
        try fx.file("Library/Containers/real/x")
        try fx.symlink("Library/Caches/com.foo.app", to: outside + "/com.foo.app")      // linked entry
        try fx.symlink("Library/Logs", to: outside)                                      // linked location
        let box = try await run(apps: [app("com.foo.app", "Foo")])
        XCTAssertTrue(box.items.isEmpty, "\(box.items.map(\.path))")
    }

    func testAppleTeamAppIsTreatedAsApple() async throws {
        try AppFixtures.makeApp(at: fx.tmp.path("Applications/Xcode.app"), bundleID: "com.apple.dt.Xcode", receipt: true)
        let roots = AppRoots(applications: fx.tmp.path("Applications"), userApplications: fx.home + "/Applications",
                             library: lib)
        let inv = try await AppInventoryScanner(roots: roots, signatures: FakeSignatures(fallback: .developerID(teamID: "59GAB85EFG")),
                                                usage: FakeUsage(), runningApps: FakeRunning()).inventory()
        XCTAssertEqual(inv.apps.first?.source, .apple)
        XCTAssertEqual(inv.apps.first?.viewOnlyReason, .apple)
    }
}
