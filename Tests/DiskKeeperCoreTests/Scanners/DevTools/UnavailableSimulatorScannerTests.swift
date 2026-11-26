import Darwin
import XCTest
@testable import DiskKeeperCore

final class UnavailableSimulatorScannerTests: XCTestCase {
    private typealias F = SimctlFixture

    func testEmitsOnlyUnavailableDevicesWithTheirFolderSizeAndOneListCall() async throws {
        let fx = try SimctlFixture()
        try fx.device(F.udidA, bytes: 20_000); try fx.device(F.udidB)
        try fx.installXcrun(listJSON: fx.listJSON([(F.udidA, false, "Shutdown", nil), (F.udidB, true, "Shutdown", nil)]))
        let (items, warnings) = try await fx.scan()
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(fx.argvLog, ["simctl list devices unavailable --json"], "the one read subcommand, once")
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.path, "\(fx.devices)/\(F.udidA)")
        XCTAssertEqual(item.cleanupMethod, .toolCommand(command: "xcrun", arguments: ["simctl", "delete", F.udidA]))
        XCTAssertEqual(item.tier, .review)
        XCTAssertEqual(item.ruleID, "tool.devtools.simulator.unavailable")
        XCTAssertEqual(item.requiresAppQuit, "com.apple.iphonesimulator")
        XCTAssertEqual(item.displayName, "Phone AA (iOS 17.5)")
        XCTAssertGreaterThanOrEqual(item.sizeLogical, 20_000)
        XCTAssertFalse(item.isVirtual)
    }

    func testSkipsSymlinkedFolderOutsideDataPathBootedAndBadUDID() async throws {
        let fx = try SimctlFixture()
        let real = try fx.home.dir("$TMP/elsewhere")
        symlink(real, "\(fx.devices)/\(F.udidA)")                       // symlinked device folder
        try fx.device(F.udidB)
        try fx.device("CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")
        try fx.device("dddddddd-dddd-4ddd-8ddd-dddddddddddd")           // lowercase: not a valid UDID
        try fx.device("EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")
        try fx.installXcrun(listJSON: fx.listJSON([
            (F.udidA, false, "Shutdown", nil),
            (F.udidB, false, "Shutdown", "/somewhere/else/data"),         // dataPath outside the folder
            ("CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC", false, "Booted", nil),
            ("dddddddd-dddd-4ddd-8ddd-dddddddddddd", false, "Shutdown", nil),
            ("EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE", false, "Shutdown", nil),
        ]))
        let (items, _) = try await fx.scan()
        XCTAssertEqual(items.map { ($0.path as NSString).lastPathComponent }, ["EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"])
    }

    func testNoDeveloperDirectoryLaunchesNothingAndWarnsNothing() async throws {
        let fx = try SimctlFixture()
        try fx.device(F.udidA)
        try fx.installXcrun(listJSON: fx.listJSON([(F.udidA, false, "Shutdown", nil)]))
        fx.hasDeveloperDir = false
        let (items, warnings) = try await fx.scan()
        XCTAssertTrue(items.isEmpty); XCTAssertTrue(warnings.isEmpty)
        XCTAssertFalse(fx.launched)
    }

    func testMissingDevicesRootLaunchesNothing() async throws {
        let fx = try SimctlFixture()
        try fx.installXcrun(listJSON: fx.listJSON([]))
        try FileManager.default.removeItem(atPath: fx.devices)
        let (items, warnings) = try await fx.scan()
        XCTAssertTrue(items.isEmpty); XCTAssertTrue(warnings.isEmpty)
        XCTAssertFalse(fx.launched)
    }

    func testFailureBadJSONAndTimeoutBecomeOneWarning() async throws {
        let fx = try SimctlFixture()
        try fx.device(F.udidA)
        try fx.installXcrun(listJSON: "not json")
        var r = try await fx.scan()
        XCTAssertEqual(r.warnings.count, 1); XCTAssertTrue(r.items.isEmpty)
        try fx.installXcrun(listJSON: "{}", listExit: 1)
        r = try await fx.scan()
        XCTAssertEqual(r.warnings.count, 1)
        try fx.installXcrun(listJSON: "{}", extra: "sleep 30")
        let slow = UnavailableSimulatorScanner(devicesRoot: fx.devices, candidates: [fx.xcrun], developer: fx.developer,
                                               runner: ToolCommandRunner(killGrace: .milliseconds(100)), timeout: .milliseconds(300))
        let c = ItemCollector()
        let started = ContinuousClock.now
        try await slow.scan(context: try fx.context(), sink: c.sink)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
        let warnings = await c.warnings
        XCTAssertEqual(warnings.count, 1)
        let items = await c.items
        XCTAssertTrue(items.isEmpty)
    }

    func testScanIsReadOnly() async throws {
        let fx = try SimctlFixture()
        try fx.device(F.udidA)
        try fx.installXcrun(listJSON: fx.listJSON([(F.udidA, false, "Shutdown", nil)]))
        func home() throws -> [String: FixtureEntry] { try fx.home.snapshot().filter { $0.key.hasPrefix("home/") } }
        let before = try home()
        _ = try await fx.scan()
        XCTAssertEqual(try home(), before)
    }

    func testGuardAllowsTheDevicesFolder() throws {
        let fx = try SimctlFixture()
        XCTAssertTrue(try fx.context().pathGuard.check("\(fx.devices)/\(F.udidA)").isAllowed)
    }

    func testBuiltInScannersIncludeIt() {
        XCTAssertTrue(BuiltInScanners.live(environment: .current()).contains { $0.id == "dev-tools.simulators" })
    }
}
