import Darwin
import XCTest
@testable import DiskKeeperCore

/// FixtureHome only: no real DerivedData, no real processes.
final class DerivedDataScannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
    private let rootRel = "Library/Developer/Xcode/DerivedData"

    private func plist(workspace: String?) -> Data {
        let dict: [String: Any] = workspace.map { ["WorkspacePath": $0, "LastAccessedDate": Date()] } ?? ["Other": 1]
        return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? Data()
    }

    @discardableResult
    private func derived(_ f: FixtureHome, _ name: String, workspace: String?, days: Double, rawPlist: Data? = nil) throws -> String {
        let dir = "\(rootRel)/\(name)"
        try f.file("\(dir)/Build/Products/out.o", bytes: 4096, modified: ago(days: days))
        if let data = rawPlist ?? (workspace == nil ? nil : plist(workspace: workspace)) {
            let path = f.abs("\(dir)/info.plist")
            XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: data))
            try FileManager.default.setAttributes([.modificationDate: ago(days: days)], ofItemAtPath: path)
        }
        for sub in ["Build/Products", "Build"] { try f.dir("\(dir)/\(sub)", modified: ago(days: days)) }
        return try f.dir(dir, modified: ago(days: days))
    }

    private func scan(_ f: FixtureHome) async throws -> [ScanItem] {
        let ctx = ScanContext(environment: f.env, pathGuard: try ScanGuard(environment: f.env, protectPatterns: []),
                              now: now, maxConcurrentSizing: 2)
        let c = ItemCollector()
        try await DerivedDataScanner.live(environment: f.env).scan(context: ctx, sink: c.sink)
        let warnings = await c.warnings
        XCTAssertTrue(warnings.isEmpty)
        return await c.items.sorted { $0.path < $1.path }
    }

    func testTiersFollowTheProjectAndTheAge() async throws {
        let f = try FixtureHome()
        let live = try f.dir("Proj/App.xcodeproj")
        try derived(f, "App-live", workspace: live, days: 30)
        try derived(f, "Gone-old", workspace: f.abs("Proj/Gone.xcodeproj"), days: 8)
        try derived(f, "Gone-recent", workspace: f.abs("Proj/Gone2.xcodeproj"), days: 2)
        try derived(f, "Gone-fresh", workspace: f.abs("Proj/Gone3.xcodeproj"), days: 0.5)
        try derived(f, "Live-fresh", workspace: live, days: 0.5)
        let items = try await scan(f)
        func tier(_ n: String) -> RiskTier? { items.first { $0.displayName == n }?.tier }
        XCTAssertEqual(tier("App-live"), .review)
        XCTAssertEqual(tier("Gone-old"), .safe)
        XCTAssertEqual(tier("Gone-recent"), .review)
        XCTAssertEqual(tier("Gone-fresh"), .keep)
        XCTAssertEqual(tier("Live-fresh"), .keep)
        let safe = try XCTUnwrap(items.first { $0.displayName == "Gone-old" })
        XCTAssertEqual(safe.ruleID, "build-caches.xcode-deriveddata")
        XCTAssertEqual(safe.tool.rawValue, "build-caches")
        XCTAssertEqual(safe.cleanupMethod, .trash)
        XCTAssertEqual(safe.project?.id, f.abs("Proj"))
        XCTAssertTrue(safe.explanation.hasPrefix("Regenerable:"))
        XCTAssertEqual(DerivedDataVariant.of(safe), .projectGone)
    }

    func testMissingOrMalformedInfoPlistIsReview() async throws {
        let f = try FixtureHome()
        try derived(f, "No-plist", workspace: nil, days: 40)
        try derived(f, "Bad-plist", workspace: nil, days: 40, rawPlist: Data("not a plist".utf8))
        try derived(f, "No-key", workspace: nil, days: 40, rawPlist: plist(workspace: nil))
        try derived(f, "Relative", workspace: "relative/App.xcodeproj", days: 40)
        try derived(f, "Dotdot", workspace: "/a/../b/App.xcodeproj", days: 40)
        let items = try await scan(f)
        XCTAssertEqual(items.count, 5)
        for item in items {
            XCTAssertEqual(item.tier, .review, item.displayName)
            XCTAssertEqual(DerivedDataVariant.of(item), .unreadable, item.displayName)
            XCTAssertNil(item.project)
        }
    }

    func testOversizePlistIsNotRead() async throws {
        let f = try FixtureHome()
        var big = plist(workspace: f.abs("Proj/Gone.xcodeproj"))
        big.append(Data(repeating: 0x20, count: DerivedDataScanner.maxPlistBytes))
        try derived(f, "Big", workspace: nil, days: 40, rawPlist: big)
        let items = try await scan(f)
        XCTAssertEqual(items.first?.tier, .review)
        XCTAssertEqual(items.first.flatMap(DerivedDataVariant.of), .unreadable)
    }

    func testSymlinkChildrenSymlinkedInfoPlistAndModuleCacheAreSkipped() async throws {
        let f = try FixtureHome()
        let elsewhere = try f.dir("elsewhere")
        try f.symlink("\(rootRel)/Linked", to: elsewhere)
        try f.file("\(rootRel)/ModuleCache.noindex/x.pcm", bytes: 100, modified: ago(days: 40))
        try f.file("\(rootRel)/modulecache.NOINDEX/x.pcm", bytes: 100, modified: ago(days: 40))
        try f.file("\(rootRel)/loose.txt", bytes: 10, modified: ago(days: 40))
        try f.file("\(rootRel)/.hidden/x", bytes: 10, modified: ago(days: 40))
        let target = f.abs("elsewhere-plist")
        _ = FileManager.default.createFile(atPath: target, contents: plist(workspace: f.abs("Proj/Gone.xcodeproj")))
        try f.file("\(rootRel)/Sym/out.o", bytes: 100, modified: ago(days: 40))
        try f.symlink("\(rootRel)/Sym/info.plist", to: target)
        try f.dir("\(rootRel)/Sym", modified: ago(days: 40))
        let items = try await scan(f)
        XCTAssertEqual(items.map(\.displayName), ["Sym"])
        XCTAssertEqual(items.first?.tier, .review, "a symlinked info.plist is not read")
        XCTAssertEqual(items.first.flatMap(DerivedDataVariant.of), .unreadable)
    }

    func testSymlinkedRootIsLeftAlone() async throws {
        let f = try FixtureHome()
        let real = try f.dir("elsewhere/DD")
        try f.file("elsewhere/DD/App-1/out.o", bytes: 100, modified: ago(days: 40))
        try f.symlink(rootRel, to: real)
        let items = try await scan(f)
        XCTAssertTrue(items.isEmpty)
    }

    func testAbsentRootGivesNothing() async throws {
        let items = try await scan(try FixtureHome())
        XCTAssertTrue(items.isEmpty)
    }

    func testProjectOnAnUnmountedVolumeIsNotGone() async throws {
        let f = try FixtureHome()
        let mounts = try f.dir("mounts")
        try f.dir("mounts/Mounted")
        let scanner = DerivedDataScanner(root: f.abs(rootRel), home: f.home, mountsRoot: mounts)
        XCTAssertFalse(scanner.projectIsGone(mounts + "/Unplugged/App.xcodeproj"))
        XCTAssertTrue(scanner.projectIsGone(mounts + "/Mounted/App.xcodeproj"))
        XCTAssertTrue(scanner.projectIsGone(f.abs("Proj/Nope.xcodeproj")))
    }

    func testVariantsAreDistinctAndRegenerable() {
        XCTAssertEqual(Set(DerivedDataVariant.allCases.map(\.explanation)).count, DerivedDataVariant.allCases.count)
        for v in DerivedDataVariant.allCases { XCTAssertTrue(v.explanation.hasPrefix("Regenerable:")) }
    }
}
