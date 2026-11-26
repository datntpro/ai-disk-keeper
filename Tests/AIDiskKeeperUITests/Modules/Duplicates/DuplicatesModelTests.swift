import DiskKeeperCore
import SwiftUI
import XCTest
@testable import DiskKeeperCore
@testable import AIDiskKeeperUI

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var minimums: [Int64] = []
    func hit(_ minimum: Int64) { lock.lock(); n += 1; minimums.append(minimum); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var seenMinimums: [Int64] { lock.lock(); defer { lock.unlock() }; return minimums }
}

/// A finder that waits for the test to release it, so phases can be observed.
private actor Gate {
    private var open = false
    func release() { open = true }
    func wait() async throws {
        while !open { try await Task.sleep(nanoseconds: 2_000_000); try Task.checkCancellation() }
    }
}

@MainActor
final class DuplicatesModelTests: XCTestCase {
    private let env = PathEnvironment(home: DupUI.home, temporaryDirectory: "/tmp/adk-t34")

    private func waitUntil(_ cond: @MainActor () async -> Bool) async {
        for _ in 0..<800 { if await cond() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func readyIndex() async -> DiskIndexModel {
        let fake = FakeDiskIndexer()
        let index = DiskIndexModel(makeIndexer: { fake }, fullDiskAccess: { false })
        index.start(.home)
        await waitUntil { await fake.isWaiting }
        await fake.finish(FakeDiskIndexer.tree())
        await waitUntil { index.phase == .ready }
        return index
    }

    private func make(_ index: DiskIndexModel, groups: [DuplicateGroup], counter: Counter = Counter(),
                      gate: Gate? = nil, progress: [DuplicateStats] = [], skipGuard: Bool = false) -> DuplicatesModel {
        let report = DupUI.report(groups)
        let env = env
        return DuplicatesModel(
            index: index,
            finder: { _, options, sink in
                counter.hit(options.minimumLogicalBytes)
                for p in progress { sink(p) }
                if let gate { try await gate.wait() }
                return report
            },
            environment: env,
            guardProvider: { try ScanGuard(environment: env, protectPatterns: []) },
            makeItems: skipGuard ? Self.itemsWithoutGuard : Self.itemsWithGuard)
    }

    /// The real scan guard resolves every path on disk; the perf test only measures the model.
    private static let itemsWithoutGuard: @Sendable (DuplicateReport, KeeperRule, ScanGuard, uid_t) -> [String: [ScanItem]] = { report, rule, _, _ in
        var out: [String: [ScanItem]] = [:]
        for g in report.groups {
            out[g.id] = g.members.map { DuplicateScanner.makeItem($0, group: g, keeper: g.keeper, rule: rule) }
        }
        return out
    }

    private static let itemsWithGuard: @Sendable (DuplicateReport, KeeperRule, ScanGuard, uid_t) -> [String: [ScanItem]] = { report, rule, pathGuard, uid in
        DuplicateScanner.items(for: report, rule: rule, pathGuard: pathGuard, userID: uid)
    }

    private func analysed(_ model: DuplicatesModel) async {
        model.analyse()
        await waitUntil { model.phase == .ready }
    }

    func testNoTreeNeedsIndex() {
        let index = DiskIndexModel(makeIndexer: { FakeDiskIndexer() }, fullDiskAccess: { false })
        let m = make(index, groups: [])
        m.refreshIfNeeded()
        XCTAssertEqual(m.phase, .needsIndex)
        XCTAssertEqual(DuplicatesView.content(phase: m.phase, hasTree: false, hasGroups: false), .needsIndex)
    }

    func testPhasesHashingThenReady() async {
        let index = await readyIndex()
        let gate = Gate()
        var stats = DuplicateStats(); stats.candidates = 10; stats.partialHashed = 4
        let m = make(index, groups: [DupUI.plain("a", count: 3)], gate: gate, progress: [stats])
        m.refreshIfNeeded()
        XCTAssertEqual(m.phase, .hashing(nil))
        await waitUntil { if case .hashing(let s?) = m.phase { return s.partialHashed == 4 } else { return false } }
        await gate.release()
        await waitUntil { m.phase == .ready }
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.groups.count, 1)
        XCTAssertEqual(m.totalSavings, 2_000_000)
        // The same index generation is not analysed twice.
        let before = m.finderRuns
        m.refreshIfNeeded()
        XCTAssertEqual(m.finderRuns, before)
    }

    func testCancelKeepsOldResults() async {
        let index = await readyIndex()
        let gate = Gate()
        let m = make(index, groups: [DupUI.plain("a", count: 2)])
        await analysed(m)
        XCTAssertEqual(m.groups.count, 1)
        let blocked = make(index, groups: [], gate: gate)
        blocked.analyse()
        XCTAssertEqual(blocked.phase, .hashing(nil))
        blocked.cancel()
        XCTAssertEqual(blocked.phase, .cancelled)
        XCTAssertEqual(DuplicatesView.content(phase: .cancelled, hasTree: true, hasGroups: true), .list)
        XCTAssertEqual(DuplicatesView.content(phase: .cancelled, hasTree: true, hasGroups: false), .stoppedEmpty)
        XCTAssertEqual(m.groups.count, 1)
    }

    func testRuleChangeReordersWithoutCallingTheFinder() async {
        let index = await readyIndex()
        let counter = Counter()
        let old = DupUI.member("/Users/tester/deep/er/old.bin", inode: 1, created: 100)
        let short = DupUI.member("/Users/tester/s.bin", inode: 2, created: 300)
        let git = DupUI.member("/Users/tester/repo/g.bin", inode: 3, git: true, created: 200)
        let m = make(index, groups: [DupUI.group("a", [old, git, short])], counter: counter)
        await analysed(m)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(m.groups[0].keeper.path, old.path)
        m.rule = .shortestPath
        XCTAssertEqual(m.groups[0].keeper.path, short.path)
        m.rule = .insideGitRepo
        XCTAssertEqual(m.groups[0].keeper.path, git.path)
        XCTAssertEqual(counter.count, 1, "a rule change must not hash again")
        XCTAssertEqual(m.selectedItems.count, 0)
        let items = m.groups[0].members.map { m.item(for: $0, in: m.groups[0]) }
        XCTAssertEqual(items.filter { $0.flags.contains(.suggestedKeeper) }.map(\.path), [git.path])
    }

    func testThresholdChangeRerunsTheFinder() async {
        let index = await readyIndex()
        let counter = Counter()
        let m = make(index, groups: [DupUI.plain("a", count: 2)], counter: counter)
        await analysed(m)
        m.minimumBytes = 10_000_000
        await waitUntil { counter.count == 2 && m.phase == .ready }
        XCTAssertEqual(counter.seenMinimums, [1_000_000, 10_000_000])
    }

    func testManualKeeperSurvivesRuleChangeAndIsNotSelectable() async {
        let index = await readyIndex()
        let g = DupUI.plain("a", count: 3)
        let m = make(index, groups: [g])
        await analysed(m)
        let pick = g.members[2]
        m.keepInstead(pick.path, in: g.id)
        XCTAssertEqual(m.groups[0].keeper.path, pick.path)
        XCTAssertTrue(m.isManualKeeper(m.groups[0]))
        m.rule = .shortestPath
        XCTAssertEqual(m.groups[0].keeper.path, pick.path)
        XCTAssertFalse(m.canSelect(pick, in: m.groups[0]))
        XCTAssertTrue(m.canSelect(g.members[0], in: m.groups[0]))
    }

    func testKeepInsteadDropsTheNewKeeperFromTheSelection() async {
        let index = await readyIndex()
        let g = DupUI.plain("a", count: 3)
        let m = make(index, groups: [g])
        await analysed(m)
        for member in m.groups[0].members { m.toggle(member, in: m.groups[0]) }
        XCTAssertEqual(m.selectedCount, 2)
        m.keepInstead(g.members[1].path, in: g.id)
        XCTAssertFalse(m.isSelected(m.groups[0].keeper, in: m.groups[0]))
        XCTAssertEqual(m.selectedCount, 1)
    }

    func testGuardDeniedMembersAreNotShown() async {
        let index = await readyIndex()
        let g = DupUI.plain("a", count: 3)
        let denied = g.members[1].path
        let env = env
        let report = DupUI.report([g])
        let m = DuplicatesModel(index: index, finder: { _, _, _ in report }, environment: env,
                                guardProvider: { try ScanGuard(environment: env, protectPatterns: [ProtectedPaths.escapeGlob(denied)]) })
        await analysed(m)
        XCTAssertEqual(m.groups[0].members.map(\.path), [g.members[0].path, g.members[2].path])
        XCTAssertNil(m.group(containing: denied))
    }

    func testReviewPassesGroupsOfEverySelectedItemAndStillGoesThroughTheEngine() async {
        let index = await readyIndex()
        let a = DupUI.plain("a", count: 3), b = DupUI.plain("b", count: 2, base: 10)
        let m = make(index, groups: [a, b])
        await analysed(m)
        for g in m.groups { m.toggle(g.members[1], in: g) }
        let engine = FakeCleanupEngine()
        let coordinator = CleanupCoordinator(holder: CleanupEngineHolder(engine: engine))
        m.reviewCleanup(using: coordinator)
        await waitUntil { if let s = coordinator.flow?.state, case .previewing = s { true } else { false } }
        let seen = await engine.lastDuplicateGroups
        XCTAssertEqual(Set(seen.keys), [a.id, b.id])
        let plan = await engine.issuedPlans.last
        XCTAssertEqual(plan?.entries.count, 2)
        let keepers = Set([a.keeper.path, b.keeper.path])
        XCTAssertTrue(plan!.entries.allSatisfy { !keepers.contains($0.item.path) })
    }

    func testForgedSelectionIsBlockedByTheEngineAndNothingExecutes() async {
        let index = await readyIndex()
        let g = DupUI.plain("a", count: 2)
        let m = make(index, groups: [g])
        await analysed(m)
        m.toggle(m.groups[0].members[1], in: m.groups[0])
        let engine = FakeCleanupEngine()
        // A forged UI state: the engine says every copy would go.
        let id = m.selectedItems[0].id
        await engine.setBlockers([id: [.wouldRemoveAllCopies(groupID: g.id)]])
        let coordinator = CleanupCoordinator(holder: CleanupEngineHolder(engine: engine))
        m.reviewCleanup(using: coordinator)
        await waitUntil { if let s = coordinator.flow?.state, case .previewing = s { true } else { false } }
        guard case .previewing(let plan, _)? = coordinator.flow?.state else { return XCTFail("no preview") }
        XCTAssertTrue(plan.executableEntries.isEmpty)
        XCTAssertEqual(plan.blockedCount, 1)
        await coordinator.flow?.confirm()
        let executed = await engine.executedPlans
        XCTAssertTrue(executed.isEmpty)
    }

    func testFinishingRemovesTrashedMembersAndDropsSmallGroups() async {
        let index = await readyIndex()
        let a = DupUI.plain("a", count: 3), b = DupUI.plain("b", count: 2, base: 10)
        let m = make(index, groups: [a, b])
        await analysed(m)
        for g in m.groups { m.toggle(g.members[1], in: g) }
        let trashed = Set(m.selectedItems.map(\.id))
        m.finished(trashed: trashed)
        XCTAssertEqual(m.groups.count, 1, "the two-member group is gone")
        XCTAssertEqual(m.groups[0].members.count, 2)
        XCTAssertEqual(m.selectedCount, 0)
        XCTAssertEqual(m.totalSavings, 1_000_000)
    }

    func testEmptyReportIsReadyAndShowsTheEmptyState() async {
        let index = await readyIndex()
        let m = make(index, groups: [])
        await analysed(m)
        XCTAssertEqual(m.phase, .ready)
        XCTAssertTrue(m.groups.isEmpty)
        XCTAssertEqual(DuplicatesView.content(phase: m.phase, hasTree: true, hasGroups: false), .empty)
        XCTAssertEqual(DuplicatesView.content(phase: .ready, hasTree: true, hasGroups: true), .list)
        XCTAssertEqual(DuplicatesView.content(phase: .hashing(nil), hasTree: true, hasGroups: false), .progress)
        XCTAssertEqual(DuplicatesView.content(phase: .failed("x"), hasTree: true, hasGroups: false), .failed("x"))
        L10n.withLanguage(.en) { XCTAssertEqual(loc("dup.empty.body", "No identical files of \(Formatting.bytes(1_000_000)) or more in your Home folder."),
                                                  "No identical files of 1 MB or more in your Home folder.") }
    }

    func testGroupsAreSortedBySavingsThenSize() async {
        let index = await readyIndex()
        let small = DupUI.plain("a", count: 2, bytes: 1_000_000)
        let big = DupUI.plain("b", count: 3, bytes: 5_000_000, base: 10)
        let m = make(index, groups: [small, big])
        await analysed(m)
        XCTAssertEqual(m.groups.map(\.id), [big.id, small.id])
    }

    func testRendersOffscreen() async {
        let index = await readyIndex()
        let m = make(index, groups: [DupUI.plain("a", count: 3)])
        await analysed(m)
        let view = DuplicatesView(model: m, index: index, cleanup: CleanupCoordinator(holder: CleanupEngineHolder()))
            .frame(width: 800, height: 600)
        let renderer = ImageRenderer(content: view)
        XCTAssertNotNil(renderer.cgImage)
        let inspector = ImageRenderer(content: DuplicatesInspector(model: m).frame(width: 300, height: 400))
        XCTAssertNotNil(inspector.cgImage)
    }

    func testReorderIsFastForTenThousandGroups() async {
        let N = 10_000
        let index = await readyIndex()
        var unique: [DuplicateGroup] = []
        unique.reserveCapacity(N)
        for i in 0..<N {
            var members: [DuplicateMember] = []
            for j in 0..<3 {
                let path: String = "/Users/tester/d\(i)/f\(j).bin"
                let inode: UInt64 = UInt64(i * 3 + j + 1)
                members.append(DupUI.member(path, inode: inode, created: Double(j) * 10 + 1))
            }
            let digest: String = String(format: "%032x%032x", i, 0)
            unique.append(DuplicateGroup(digest: digest, partialDigest: "p", logicalBytes: 1_000_000, members: members))
        }
        let m = make(index, groups: unique, skipGuard: true)
        let start = ContinuousClock.now
        m.analyse()
        for _ in 0..<4000 where m.phase != .ready { try? await Task.sleep(nanoseconds: 5_000_000) }
        print("analyse 10k groups (guard + items):", ContinuousClock.now - start)
        XCTAssertEqual(m.groups.count, N)
        let clock = ContinuousClock()
        // Median of 5 runs (a single run is noisy on shared CI); CI gets twice the limit.
        let scale: Int64 = ProcessInfo.processInfo.environment["CI"] != nil ? 2 : 1
        func median(_ body: () -> Void) -> Duration {
            let runs = (0..<5).map { _ in clock.measure(body) }.sorted()
            return runs[2]
        }
        let rules: [KeeperRule] = [.insideGitRepo, .oldest]
        var flip = 0
        let t = median { flip += 1; m.rule = rules[flip % 2] }
        print("reorder 10k groups (median of 5):", t)
        XCTAssertLessThan(t, .milliseconds(250 * scale))
        // toggle is O(1) in the number of groups: 1 000 toggles stay quick.
        let t2 = median { for g in m.groups.prefix(1000) { m.toggle(g.members[1], in: g) } }
        print("1000 toggles (median of 5):", t2)
        XCTAssertLessThan(t2, .milliseconds(500 * scale))
    }
}
