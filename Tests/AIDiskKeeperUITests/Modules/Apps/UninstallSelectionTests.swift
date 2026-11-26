import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

final class UninstallSelectionTests: XCTestCase {
    private func group() -> UninstallGroup { UninstallGroup(related: UninstallFix.slideItems, shared: [UninstallFix.sharedItem]) }

    func testExactIsPreTickedNameAndSharedNever() {
        let g = group()
        let s = UninstallSelection(app: UninstallFix.slide, group: g)
        let ticked = s.items(in: g).map(\.ruleID)
        XCTAssertEqual(Set(ticked), ["apps.leftover.exact"])
        XCTAssertEqual(s.items(in: g).count, 4) // Caches, Application Support, saved state, launch agent
        XCTAssertFalse(s.isTicked(g.related.first { $0.ruleID == "apps.leftover.name" }!))
        XCTAssertFalse(s.isTicked(UninstallFix.sharedItem))
    }

    func testNoneMethodCannotBeTicked() {
        let g = group()
        let none = g.related.first { $0.cleanupMethod == .none }!
        XCTAssertFalse(UninstallSelection.canToggle(none, in: g))
        var s = UninstallSelection(app: UninstallFix.slide, group: g)
        s.toggle(none, in: g)
        XCTAssertFalse(s.isTicked(none))
    }

    func testSharedGoOneAtATime() {
        let second = UninstallFix.leftover(nil, "WebKit", "Slidecraft", rule: "apps.leftover.name", size: 3)
        let g = UninstallGroup(related: [], shared: [UninstallFix.sharedItem, second])
        var s = UninstallSelection(app: UninstallFix.slide, group: g)
        s.toggle(UninstallFix.sharedItem, in: g)
        s.toggle(second, in: g)
        XCTAssertEqual(s.items(in: g).map(\.id), [second.id])
    }

    func testSwitchingAppsResets() {
        let g = group()
        var s = UninstallSelection(app: UninstallFix.slide, group: g)
        s.toggle(g.related[0], in: g)
        let other = UninstallFix.app("Notely")
        let fresh = UninstallSelection(app: other, group: UninstallGroup())
        XCTAssertEqual(fresh.appID, other.id)
        XCTAssertTrue(fresh.ticked.isEmpty)
        XCTAssertNotEqual(fresh, s)
    }

    func testResetSetIsRegenerableStateOnly() {
        let g = group()
        let reset = g.resetItems.map { UninstallLibrary.location(of: $0.path) }
        XCTAssertEqual(Set(reset), ["Caches", "Saved Application State"])
        for loc in ["Application Support", "Containers", "Preferences", "LaunchAgents"] {
            XCTAssertFalse(UninstallLibrary.resetLocations.contains(loc), loc)
        }
        // A name-level cache is not "exact": never part of the reset.
        let nameCache = UninstallFix.leftover(UninstallFix.slide, "Caches", "Slidecraft", rule: "apps.leftover.name")
        XCTAssertFalse(UninstallLibrary.isRegenerable(nameCache))
    }

    func testRandomTogglesNeverTickAnotherAppsItems() {
        let g = group()
        let foreign = UninstallFix.leftover(UninstallFix.app("Other"), "Caches", "com.test.other")
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var s = UninstallSelection(app: UninstallFix.slide, group: g)
            for _ in 0..<12 {
                let pool = g.all + [foreign]
                s.toggle(pool.randomElement(using: &rng)!, in: g)
            }
            XCTAssertFalse(s.isTicked(foreign))
            XCTAssertTrue(s.ticked.isSubset(of: Set(g.all.map(\.id))))
            XCTAssertLessThanOrEqual(s.items(in: g).filter { g.shared.contains($0) }.count, 1)
        }
    }

    func testLibraryHelpers() {
        XCTAssertEqual(UninstallLibrary.tilde("/h/Library/Caches/x", home: "/h"), "~/Library/Caches/x")
        XCTAssertEqual(UninstallLibrary.tilde("/other/x", home: "/h"), "/other/x")
        XCTAssertEqual(UninstallLibrary.orphanKey(UninstallFix.leftover(nil, "Saved Application State", "com.a.b.savedState")), "com.a.b")
        XCTAssertEqual(UninstallRelatedKind(UninstallFix.sharedItem), .shared)
        XCTAssertEqual(UninstallRelatedKind(UninstallFix.slideItems[3]), .launchAgent)
    }
}
