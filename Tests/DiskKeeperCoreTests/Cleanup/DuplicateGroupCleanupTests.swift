import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

/// Keep-one invariant (PLAN invariant 13), through the real engine and a fake trash that moves into a fixture dir.
final class DuplicateGroupCleanupTests: CleanupTestCase {
    private let size = 1_500_000

    private struct Setup {
        var paths: [String]            // keeper first
        var group: DuplicateGroup
        var items: [ScanItem]
        var groups: [String: DuplicateGroup] { [group.id: group] }
    }

    /// Writes `names` (same content, birth times ascending so names[0] is the keeper) and finds the group.
    private func makeGroup(_ names: [String] = ["a", "b", "c"], seed: UInt64 = 1,
                           links: [String: String] = [:]) async throws -> Setup {
        let content = DupFix.data(seed: seed, count: size)
        var paths: [String] = []
        for (i, n) in names.enumerated() {
            let p = try DupFix.write(fx.path("home/docs/\(n)"), content)
            try DupFix.setBirthTime(p, Date(timeIntervalSinceNow: Double(-9000 + i * 100)))
            paths.append(p)
        }
        for (src, dst) in links { XCTAssertEqual(Darwin.link(fx.path("home/docs/\(src)"), fx.path("home/docs/\(dst)")), 0) }
        let env = PathEnvironment(home: home, temporaryDirectory: fx.path("tmp"), variables: [:])
        let tree = try await DiskIndexer(environment: env, pathGuard: try makeGuard()).index(.home)
        var options = DuplicateOptions(environment: env)
        options.minimumLogicalBytes = 1_000_000
        let report = try await DuplicateFinder(options: options).find(in: tree)
        let group = try XCTUnwrap(report.groups.first)
        XCTAssertEqual(group.members.map(\.path), paths.filter { p in
            !links.values.contains { fx.path("home/docs/\($0)") == p } })
        let items = group.members.map {
            DuplicateScanner.makeItem($0, group: group, keeper: group.keeper, rule: .oldest)
        }
        return Setup(paths: group.members.map(\.path), group: group, items: items)
    }

    private func codes(_ e: CleanupPlanEntry) -> [String] { e.blockers.map(\.code) }

    func testSelectingAllMembersBlockedAtPlan() async throws {
        let s = try await makeGroup()
        let engine = try makeEngine()
        let plan = await engine.plan(s.items, duplicateGroups: s.groups)
        for e in plan.entries {
            XCTAssertTrue(codes(e).contains("wouldRemoveAllCopies"), "\(codes(e))")
            XCTAssertFalse(e.isExecutable)
        }
        let report = try await engine.execute(plan)
        XCTAssertTrue(trashContents().isEmpty)
        for p in s.paths { XCTAssertTrue(FileManager.default.fileExists(atPath: p)) }
        XCTAssertTrue(report.results.allSatisfy { if case .skipped = $0.outcome { true } else { false } })
    }

    func testSelectingAllButKeeperAllowed() async throws {
        let s = try await makeGroup()
        let engine = try makeEngine()
        let plan = await engine.plan(Array(s.items.dropFirst()), duplicateGroups: s.groups)
        for e in plan.entries {
            XCTAssertTrue(e.isExecutable, "\(codes(e))")
            XCTAssertEqual(e.survivors?.survivors.map(\.path), [s.paths[0]])
            XCTAssertEqual(e.survivors?.groupID, s.group.id)
        }
        let report = try await engine.execute(plan)
        XCTAssertEqual(trashContents().count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.paths[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.paths[1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.paths[2]))
        XCTAssertEqual(report.results.count, 2)
    }

    func testKeeperDeletedAfterPlanBlocksAtExecute() async throws {
        let s = try await makeGroup()
        let engine = try makeEngine()
        let plan = await engine.plan(Array(s.items.dropFirst()), duplicateGroups: s.groups)
        XCTAssertEqual(unlink(s.paths[0]), 0)
        let report = try await engine.execute(plan)
        XCTAssertTrue(trashContents().isEmpty)
        for r in report.results { XCTAssertEqual(skippedCodes(r.outcome), ["survivorChanged"]) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.paths[1]))
    }

    func testKeeperReplacedWithDifferentContentBlocksAtExecute() async throws {
        let s = try await makeGroup()
        let engine = try makeEngine()
        let plan = await engine.plan(Array(s.items.dropFirst()), duplicateGroups: s.groups)
        // same size, different head, written in place (same inode, mtime within the slack)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: s.paths[0]))
        try h.write(contentsOf: Data(repeating: 0xEE, count: 4096))
        try h.close()
        let report = try await engine.execute(plan)
        XCTAssertTrue(trashContents().isEmpty)
        for r in report.results { XCTAssertEqual(skippedCodes(r.outcome), ["survivorChanged"]) }
    }

    func testChangedSurvivorAtPlanTimeBlocksEverySelectedCopy() async throws {
        let s = try await makeGroup()
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: s.paths[0]))
        try h.write(contentsOf: Data(repeating: 0xEE, count: 4096))
        try h.close()
        // keeper is now different: only the third copy (still identical) could survive
        let plan = await (try makeEngine()).plan([s.items[1]], duplicateGroups: s.groups)
        XCTAssertEqual(plan.entries[0].survivors?.survivors.map(\.path), [s.paths[2]])
        let onlyBad = await (try makeEngine()).plan([s.items[1], s.items[2]], duplicateGroups: s.groups)
        for e in onlyBad.entries { XCTAssertTrue(codes(e).contains("wouldRemoveAllCopies")) }
    }

    func testHardLinkNameIsNotASurvivor() async throws {
        let s = try await makeGroup(["a", "b"], links: ["a": "a-link"])
        XCTAssertEqual(s.group.members[0].otherLinkPaths, [fx.path("home/docs/a-link")])
        let engine = try makeEngine()
        let blocked = await engine.plan(s.items, duplicateGroups: s.groups)
        for e in blocked.entries { XCTAssertTrue(codes(e).contains("wouldRemoveAllCopies")) }
        // selecting only B keeps A (the inode), with its other name beside it
        let ok = await engine.plan([s.items[1]], duplicateGroups: s.groups)
        XCTAssertTrue(ok.entries[0].isExecutable, "\(codes(ok.entries[0]))")
        // the link name is not a group member: it cannot be reasoned about, so it fails closed
        let linkItem = DuplicateScanner.makeItem(s.group.members[0], group: s.group, keeper: s.group.keeper, rule: .oldest)
        let asLink = ScanItem(url: URL(fileURLWithPath: fx.path("home/docs/a-link")), displayName: "a-link",
                              tool: linkItem.tool, category: .duplicate, sizeAllocated: linkItem.sizeAllocated,
                              sizeLogical: linkItem.sizeLogical, fileCount: 1, lastModified: linkItem.lastModified,
                              tier: .review, explanation: "x", ruleID: "duplicates.copy", groupID: s.group.id)
        let plan = await engine.plan([asLink, s.items[1]], duplicateGroups: s.groups)
        XCTAssertTrue(codes(plan.entries[0]).contains("duplicateGroupUnknown"))
    }

    func testPlanWithoutGroupsFailsClosed() async throws {
        let s = try await makeGroup()
        let engine = try makeEngine()
        let plan = await engine.plan(s.items)
        for e in plan.entries { XCTAssertTrue(codes(e).contains("duplicateGroupUnknown")) }
        let wrong = await engine.plan(s.items, duplicateGroups: ["dup:other:1": s.group])
        for e in wrong.entries { XCTAssertTrue(codes(e).contains("duplicateGroupUnknown")) }
        _ = try await engine.execute(plan)
        XCTAssertTrue(trashContents().isEmpty)
    }

    func testTwoSelectedMembersCannotSurviveEachOther() async throws {
        let s = try await makeGroup()
        let engine = try makeEngine()
        let selected = [s.items[0], s.items[1]]
        let plan = await engine.plan(selected, duplicateGroups: s.groups)
        for e in plan.entries { XCTAssertEqual(e.survivors?.survivors.map(\.path), [s.paths[2]]) }
        XCTAssertEqual(unlink(s.paths[2]), 0)
        let report = try await engine.execute(plan)
        XCTAssertTrue(trashContents().isEmpty)
        for r in report.results { XCTAssertEqual(skippedCodes(r.outcome), ["survivorChanged"]) }
        for p in s.paths.prefix(2) { XCTAssertTrue(FileManager.default.fileExists(atPath: p)) }
    }

    func testSurvivorsArePartOfPlanEquality() async throws {
        let s = try await makeGroup()
        let engine = try makeEngine()
        let plan = await engine.plan(Array(s.items.dropFirst()), duplicateGroups: s.groups)
        let e = plan.entries[0]
        let forged = DuplicateSurvivorSet(groupID: e.survivors!.groupID, logicalBytes: e.survivors!.logicalBytes,
                                          partialDigest: e.survivors!.partialDigest,
                                          survivors: [SurvivorFingerprint(path: s.paths[1], device: 1, inode: 1, modified: Date())])
        let tampered = CleanupPlan(id: plan.id, createdAt: plan.createdAt, entries: [
            CleanupPlanEntry(item: e.item, action: e.action, blockers: e.blockers, fingerprint: e.fingerprint, survivors: forged),
            plan.entries[1]])
        do { _ = try await engine.execute(tampered); XCTFail("expected planModified") }
        catch { XCTAssertEqual(error as? CleanupError, .planModified) }
        XCTAssertTrue(trashContents().isEmpty)
    }

    func testPlanRoundTripsThroughJSON() async throws {
        let s = try await makeGroup()
        let plan = await (try makeEngine()).plan(Array(s.items.dropFirst()), duplicateGroups: s.groups)
        let data = try DiskKeeperJSON.makeEncoder().encode(plan)
        let back = try DiskKeeperJSON.makeDecoder().decode(CleanupPlan.self, from: data)
        // Dates are encoded at coarser precision than a stat() timestamp, so compare what the audit needs.
        XCTAssertEqual(back.entries.map { $0.survivors?.survivors.map { $0.path } ?? [] }, plan.entries.map { $0.survivors?.survivors.map { $0.path } ?? [] })
        XCTAssertEqual(back.entries.map(\.survivors?.partialDigest), plan.entries.map(\.survivors?.partialDigest))
        XCTAssertEqual(back.entries.map(\.id), plan.entries.map(\.id))
    }

    // MARK: Survivors claimed by other plan items (any category, folders included), in any order

    private func exec(_ s: Setup, _ items: [ScanItem]) async throws -> (CleanupPlan, CleanupReport) {
        let engine = try makeEngine()
        let plan = await engine.plan(items, duplicateGroups: s.groups)
        return (plan, try await engine.execute(plan))
    }

    private func nonDupItem(_ rel: String) throws -> ScanItem { try item(rel, rule: "r.other", tier: .review) }

    /// VA1: the survivor itself is another (non-duplicate) item of the plan.
    func testSurvivorSelectedAsNonDuplicateItemBlocksBothOrders() async throws {
        for dupFirst in [true, false] {
            fx = try TemporaryDirectory(); try fx.dir("home"); try fx.dir("tmp"); try fx.dir("Trash")
            let s = try await makeGroup(["a", "b"])
            let other = try nonDupItem("home/docs/a")
            let items = dupFirst ? [s.items[1], other] : [other, s.items[1]]
            let (plan, report) = try await exec(s, items)
            let dupEntry = try XCTUnwrap(plan.entries.first { $0.item.id == s.items[1].id })
            XCTAssertTrue(codes(dupEntry).contains("wouldRemoveAllCopies"), "dupFirst=\(dupFirst) \(codes(dupEntry))")
            XCTAssertTrue(FileManager.default.fileExists(atPath: s.paths[1]), "dupFirst=\(dupFirst): copy b must stay")
            _ = report
        }
    }

    /// VA2: a folder item contains the survivor.
    func testFolderContainingSurvivorBlocksBothOrders() async throws {
        for dupFirst in [true, false] {
            fx = try TemporaryDirectory(); try fx.dir("home"); try fx.dir("tmp"); try fx.dir("Trash")
            let s = try await makeGroup(["k/a", "b"])
            let folder = try nonDupItem("home/docs/k")
            let items = dupFirst ? [s.items[1], folder] : [folder, s.items[1]]
            let (plan, report) = try await exec(s, items)
            let dupEntry = try XCTUnwrap(plan.entries.first { $0.item.id == s.items[1].id })
            XCTAssertTrue(codes(dupEntry).contains("wouldRemoveAllCopies"), "dupFirst=\(dupFirst) \(codes(dupEntry))")
            XCTAssertTrue(FileManager.default.fileExists(atPath: s.paths[1]), "dupFirst=\(dupFirst): copy b must stay")
            _ = report
        }
    }

    /// With a third copy, a claimed survivor is skipped and the remaining one is used.
    func testClaimedSurvivorIsSkippedWhenAnotherRemains() async throws {
        let s = try await makeGroup(["a", "b", "c"])
        let other = try nonDupItem("home/docs/a")
        let (plan, _) = try await exec(s, [s.items[1], other])
        let e = try XCTUnwrap(plan.entries.first { $0.item.id == s.items[1].id })
        XCTAssertEqual(e.survivors?.survivors.map(\.path), [s.paths[2]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.paths[2]))
    }

    /// Execute-time mirror: a plan whose survivor is claimed by a later entry is refused by the gate even if
    /// the survivor list was valid when planned (entries are bound, so build it through a hand-made engine run).
    func testGateRefusesSurvivorUnderAnotherEntryAtExecute() async throws {
        let s = try await makeGroup(["k/a", "b"])
        let engine = try makeEngine()
        let entry = CleanupPlanEntry(
            item: s.items[1], action: .trash, blockers: [], fingerprint: nil,
            survivors: DuplicateSurvivorSet(
                groupID: s.group.id, logicalBytes: s.group.logicalBytes, partialDigest: s.group.partialDigest,
                survivors: [SurvivorFingerprint(path: s.paths[0], device: s.group.members[0].device,
                                                inode: s.group.members[0].inode, modified: s.group.members[0].modified)]))
        let folderKey = PathCanonicalizer.key(fx.path("home/docs/k"))
        let gate = await engine.keepOneGate(entry, trashedKeys: [], claimed: [folderKey])
        XCTAssertEqual(gate?.code, "survivorChanged")
        let free = await engine.keepOneGate(entry, trashedKeys: [], claimed: [])
        XCTAssertNil(free)
    }

    /// A forged group listing one inode under two paths cannot make the only copy a survivor of itself.
    func testForgedSameInodeGroupIsRejected() async throws {
        let s = try await makeGroup(["a", "b"])
        let m = s.group.members[1]
        // member "b" listed again as a second "copy" of itself through a hard-link path
        let alias = fx.path("home/docs/b-alias")
        XCTAssertEqual(Darwin.link(m.path, alias), 0)
        let forgedMember = DuplicateMember(
            path: alias, device: m.device, inode: m.inode, otherLinkPaths: [], logicalBytes: m.logicalBytes,
            allocatedBytes: m.allocatedBytes, reclaimableBytes: m.reclaimableBytes, sharesStorage: false,
            sharesAllStorage: false, created: m.created, modified: m.modified, isInGitRepo: false)
        let forged = DuplicateGroup(digest: s.group.digest, partialDigest: s.group.partialDigest,
                                    logicalBytes: s.group.logicalBytes, members: [forgedMember, m])
        let engine = try makeEngine()
        let item = DuplicateScanner.makeItem(m, group: forged, keeper: forged.keeper, rule: .oldest)
        let plan = await engine.plan([item], duplicateGroups: [forged.id: forged])
        XCTAssertTrue(codes(plan.entries[0]).contains("wouldRemoveAllCopies"), "\(codes(plan.entries[0]))")
    }

    func testNonDuplicateEntriesHaveNoSurvivors() async throws {
        try fx.file("home/cache/a/f", bytes: 3000)
        let plan = await (try makeEngine()).plan([try item("home/cache/a")], duplicateGroups: [:])
        XCTAssertNil(plan.entries[0].survivors)
        XCTAssertTrue(plan.entries[0].isExecutable)
    }
}
