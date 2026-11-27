import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class CleanupCoordinatorTests: XCTestCase {
    private let items = [ItemFixtures.item("a"), ItemFixtures.item("b", tier: .review)]

    private func waitUntil(_ cond: @MainActor () -> Bool) async {
        for _ in 0..<600 where !cond() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func member(_ path: String, inode: UInt64) -> DuplicateMember {
        DuplicateMember(path: path, device: 1, inode: inode, otherLinkPaths: [], logicalBytes: 10, allocatedBytes: 10,
                        reclaimableBytes: nil, sharesStorage: false, sharesAllStorage: false,
                        created: .distantPast, modified: .distantPast, isInGitRepo: false)
    }

    private func group() -> [String: DuplicateGroup] {
        let g = DuplicateGroup(digest: String(repeating: "a", count: 64), partialDigest: "p", logicalBytes: 10, members: [
            member("/tmp/x/1", inode: 1),
            member("/tmp/x/2", inode: 2),
        ])
        return ["g1": g]
    }

    private func make() -> (CleanupCoordinator, FakeCleanupEngine) {
        let engine = FakeCleanupEngine()
        return (CleanupCoordinator(holder: CleanupEngineHolder(engine: engine)), engine)
    }

    /// #92: a second `review` while a flow is active is a no-op: the running flow keeps its own callback.
    func testReviewIsRefusedWhileAFlowIsActive() async {
        let (c, engine) = make()
        var firstFinished = false, secondFinished = false
        c.review(items) { _ in firstFinished = true }
        await waitUntil { c.flow?.isActive == true && !(c.flow?.state.isPlanning ?? true) }
        let flow = c.flow
        c.review([ItemFixtures.item("z")]) { _ in secondFinished = true }
        XCTAssertTrue(c.flow === flow)
        c.finished([])
        XCTAssertTrue(firstFinished); XCTAssertFalse(secondFinished)
        let plans = await engine.issuedPlans.count
        XCTAssertEqual(plans, 1)
    }

    /// The Go menu lists only enabled modules, at most nine (⌘1…⌘9), in sidebar order.
    func testGoMenuListsOnlyEnabledModulesInOrder() {
        let menu = ScanCommands.goMenuModules()
        XCTAssertLessThanOrEqual(menu.count, 9)
        XCTAssertTrue(menu.allSatisfy(\.isEnabled))
        XCTAssertEqual(menu.map(\.id), Array(ModuleRegistry.enabled().map(\.id).prefix(9)))
        XCTAssertEqual(Set(menu.map(\.id)).count, menu.count)
    }

    func testReviewPassesDuplicateGroupsToTheEngine() async {
        let (c, engine) = make()
        let groups = group()
        c.review(items, duplicateGroups: groups) { _ in }
        await waitUntil { c.flow.map { if case .previewing = $0.state { true } else { false } } ?? false }
        XCTAssertTrue(c.isPresented)
        let seen = await engine.lastDuplicateGroups
        XCTAssertEqual(seen, groups)
    }

    func testRecheckKeepsTheGroups() async throws {
        let (c, engine) = make()
        let groups = group()
        c.review(items, duplicateGroups: groups) { _ in }
        await waitUntil { c.flow?.isActive == true && !(c.flow?.state.isPlanning ?? true) }
        await c.flow?.recheck()
        let seen = await engine.lastDuplicateGroups
        XCTAssertEqual(seen, groups)
        let plans = await engine.issuedPlans.count
        XCTAssertEqual(plans, 2)
    }

    func testFinishedForwardsTrashedIDsOnce() async {
        let (c, _) = make()
        var got: [Set<ScanItem.ID>] = []
        c.review(items) { got.append($0) }
        await waitUntil { c.isPresented }
        c.finished(["x", "y"])
        c.finished(["z"])
        XCTAssertEqual(got, [["x", "y"]])
    }

    func testDismissResets() async {
        let (c, _) = make()
        c.review(items) { _ in }
        await waitUntil { c.isPresented }
        c.dismiss()
        XCTAssertFalse(c.isPresented)
    }

    func testNoEngineMeansNoSheet() {
        let c = CleanupCoordinator(holder: CleanupEngineHolder(error: "nope"))
        c.review(items) { _ in }
        XCTAssertFalse(c.isPresented)
        XCTAssertNil(c.flow)
    }
}

private extension CleanupFlowModel.State {
    var isPlanning: Bool { if case .planning = self { true } else { false } }
}
