import Foundation
import XCTest
@testable import DiskKeeperCore

final class InUseAdjusterTests: XCTestCase {
    private var fx: FixtureHome!
    private let now = Date()
    private var context: ScanContext!

    override func setUpWithError() throws {
        fx = try FixtureHome()
        let g = try ScanGuard(environment: fx.env, protectPatterns: [])
        context = ScanContext(environment: fx.env, pathGuard: g, now: now, maxConcurrentSizing: 1)
    }

    private func item(_ rel: String, tier: RiskTier = .safe, age: TimeInterval = 7200,
                      method: CleanupMethod = .trash, path: String? = nil) -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: path ?? fx.abs(rel)), displayName: rel, tool: "t", category: .aiToolData,
                 sizeAllocated: 10, sizeLogical: 10, fileCount: 1, lastModified: now.addingTimeInterval(-age),
                 tier: tier, explanation: "x", ruleID: "t.r", cleanupMethod: method)
    }

    private func hold(_ path: String) -> ProcessHold { ProcessHold(pid: 42, name: "tail", uid: getuid(), openPaths: [path]) }

    func testHeldItemsBecomeKeepWithInUse() async {
        let safe = item("logs"), review = item("cache", tier: .review)
        let src = FakeUsageSource([hold(safe.path + "/a.log"), hold(review.path)])
        let out = await InUseAdjuster(source: src).adjust([safe, review], context: context)
        for i in out.items {
            XCTAssertEqual(i.tier, .keep)
            XCTAssertTrue(i.flags.contains(.inUse))
            XCTAssertEqual(i.inUseBy, "tail"); XCTAssertEqual(i.inUsePID, 42)
            XCTAssertEqual(i.explanation, "x", "no English baked into explanation")
        }
        XCTAssertTrue(out.warnings.isEmpty)
        XCTAssertEqual(src.callCount, 1, "one snapshot per scan")
    }

    func testRecentMtimeBecomesKeepWithoutHolder() async {
        let out = await InUseAdjuster(source: FakeUsageSource([])).adjust(
            [item("a", age: 1800), item("b", age: 7200)], context: context)
        XCTAssertEqual(out.items[0].tier, .keep)
        XCTAssertTrue(out.items[0].flags.contains(.inUse))
        XCTAssertNil(out.items[0].inUseBy)
        XCTAssertEqual(out.items[1].tier, .safe)
        XCTAssertTrue(out.items[1].flags.isEmpty)
    }

    func testKeepAppsAndVirtualItemsAreUntouched() async {
        let keep = item("k", tier: .keep)
        let app = item("Foo.app", method: .trashApplication(bundleID: "com.x.foo"), path: fx.abs("Foo.app"))
        let virtual = item("v", method: .toolCommand(command: "x", arguments: []), path: VirtualItemPath.build(namespace: "docker", target: "t1", kind: "image", id: "abc")!)
        XCTAssertTrue(virtual.isVirtual)
        let src = FakeUsageSource([hold(keep.path), hold(app.path), ProcessHold(pid: 1, name: "d", uid: getuid(), cwd: "/")])
        let all = [keep, app, virtual].map { var i = $0; i.lastModified = now; return i }
        let out = await InUseAdjuster(source: src).adjust(all, context: context)
        XCTAssertEqual(out.items, all)
    }

    func testUnreadableSnapshotChangesNothingAndWarns() async {
        let a = item("a")
        let out = await InUseAdjuster(source: FakeUsageSource(nil)).adjust([a], context: context)
        XCTAssertEqual(out.items, [a])
        XCTAssertEqual(out.warnings.map(\.code), [.inUseUnknown])
    }

    func testResultIsMonotonic() async {
        let items = [item("a"), item("b", tier: .review)]
        let out = await InUseAdjuster(source: FakeUsageSource([hold(items[0].path)])).adjust(items, context: context)
        XCTAssertTrue(AdjusterValidation.isMonotonic(before: items, after: out.items))
    }

    func testScanItemCodableKeepsInUseFields() throws {
        var i = item("a"); i.inUseBy = "tail"; i.inUsePID = 7
        let back = try JSONDecoder().decode(ScanItem.self, from: JSONEncoder().encode(i))
        XCTAssertEqual(back, i)
        var plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item("b"))) as! [String: Any]
        plain.removeValue(forKey: "inUseBy")
        XCTAssertNoThrow(try JSONDecoder().decode(ScanItem.self, from: JSONSerialization.data(withJSONObject: plain)))
    }
}
