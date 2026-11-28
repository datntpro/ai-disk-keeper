import XCTest
@testable import DiskKeeperCore

/// FixtureHome only. Also pins the symlinked-root rule for both scanners that can make Safe items.
final class TartTmpScannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func scan(_ f: FixtureHome, derived: Bool = false) async throws -> [ScanItem] {
        let ctx = ScanContext(environment: f.env, pathGuard: try ScanGuard(environment: f.env, protectPatterns: []),
                              now: now, maxConcurrentSizing: 2)
        let c = ItemCollector()
        if derived {
            try await DerivedDataScanner.live(environment: f.env).scan(context: ctx, sink: c.sink)
        } else {
            try await TartTmpScanner.live(environment: f.env).scan(context: ctx, sink: c.sink)
        }
        return await c.items.sorted { $0.path < $1.path }
    }

    private func dir(_ f: FixtureHome, _ rel: String, days: Double) throws {
        try f.file(rel + "/payload.bin", bytes: 4096, modified: ago(days: days))
        try f.dir(rel, modified: ago(days: days))
    }

    func testOldIsSafeFreshIsKeptAndSymlinksAreSkipped() async throws {
        let f = try FixtureHome()
        try dir(f, ".tart/tmp/old-pull", days: 3)
        try dir(f, ".tart/tmp/fresh-pull", days: 0.5)
        try f.file(".tart/tmp/loose.part", bytes: 10, modified: ago(days: 5))
        try f.symlink(".tart/tmp/link", to: f.abs(".tart/tmp/old-pull"))
        let items = try await scan(f)
        XCTAssertEqual(items.map { ($0.displayName, $0.tier) }.map { "\($0.0):\($0.1)" },
                       ["fresh-pull:keep", "loose.part:safe", "old-pull:safe"])
        XCTAssertTrue(items.allSatisfy { $0.ruleID == "build-caches.tart-tmp" && $0.cleanupMethod == .trash })
        XCTAssertEqual(items.compactMap(TartTmpVariant.of).count, 3)
    }

    func testAbsentRootGivesNothing() async throws {
        let items = try await scan(try FixtureHome())
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: symlinked roots (verifier A1/A7)

    func testSymlinkedTartParentGivesNoItemsInOrdinaryFolders() async throws {
        let f = try FixtureHome()
        try dir(f, "Documents/stuff/tmp/report-2025", days: 30)
        try f.symlink(".tart", to: f.abs("Documents/stuff"))
        let items = try await scan(f)
        XCTAssertTrue(items.isEmpty, "\(items.map(\.path))")
    }

    func testSymlinkedTmpContainerGivesNoItems() async throws {
        let f = try FixtureHome()
        try dir(f, "Documents/report", days: 30)
        try f.dir(".tart")
        try f.symlink(".tart/tmp", to: f.abs("Documents"))
        let items = try await scan(f)
        XCTAssertTrue(items.isEmpty)
    }

    func testSymlinkedXcodeParentGivesNoDerivedDataItems() async throws {
        let f = try FixtureHome()
        let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": f.abs("Gone/T.xcodeproj")],
                                                       format: .xml, options: 0)
        try dir(f, "Documents/Work/DerivedData/MyThesis", days: 30)
        XCTAssertTrue(FileManager.default.createFile(atPath: f.abs("Documents/Work/DerivedData/MyThesis/info.plist"), contents: plist))
        try FileManager.default.setAttributes([.modificationDate: ago(days: 30)],
                                              ofItemAtPath: f.abs("Documents/Work/DerivedData/MyThesis/info.plist"))
        try f.dir("Library/Developer")
        try f.symlink("Library/Developer/Xcode", to: f.abs("Documents/Work"))
        let items = try await scan(f, derived: true)
        XCTAssertTrue(items.isEmpty, "\(items.map { "\($0.path) \($0.tier)" })")
    }

    func testRootResolvingToItselfIsAccepted() throws {
        let f = try FixtureHome()
        try f.dir(".tart/tmp")
        XCTAssertTrue(BuildCacheRoot.resolvesToItself(f.abs(".tart/tmp"), home: f.home))
        try f.dir("elsewhere")
        try f.symlink(".tart/tmp/x", to: f.abs("elsewhere"))
        XCTAssertFalse(BuildCacheRoot.resolvesToItself(f.abs(".tart/tmp/x"), home: f.home))
        XCTAssertFalse(BuildCacheRoot.resolvesToItself(f.abs("missing/root"), home: f.home))
        XCTAssertFalse(BuildCacheRoot.resolvesToItself("/elsewhere/root", home: f.home))
    }
}
