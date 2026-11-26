import XCTest
@testable import DiskKeeperCore

final class DiskMapOverlayTests: XCTestCase {
    static func item(_ path: String, bytes: Int64, category: ItemCategory = .buildArtifact, tool: ToolID = .claudeCode,
                     tier: RiskTier = .safe, id: String? = nil) -> ScanItem {
        ScanItem(id: id ?? path, url: URL(fileURLWithPath: path), displayName: "x", tool: tool, category: category, project: nil,
                 sizeAllocated: bytes, sizeLogical: bytes, fileCount: 1, lastModified: nil, tier: tier, explanation: "",
                 ruleID: "r", cleanupMethod: .trash, requiresAppQuit: nil, flags: [], groupID: nil)
    }

    let tree = MapFix.tree([
        .dir("a", [.dir("b", [.file("f", bytes: 1000)]), .file("g", bytes: 200)]),
        .dir("Pack.app", flags: [.package, .collapsed]),
        .dir("prot", flags: [.protected], [.file("p", bytes: 50)]),
    ])

    func id(_ path: String) -> DiskNodeID { tree.lookup(path: MapFix.root + path)! }

    func testItemUnderFolderColoursRightNode() {
        let o = DiskMapOverlay.build(tree: tree, items: [Self.item("/synthetic/a/b", bytes: 900, category: .worktree, tool: .cursor, tier: .review)])
        let b = o.attribution(id("/a/b"))!
        XCTAssertTrue(b.isExact); XCTAssertEqual(b.dominantCategory, .worktree); XCTAssertEqual(b.itemIDs, ["/synthetic/a/b"])
        XCTAssertEqual(b.tiers, [.review]); XCTAssertEqual(b.dominantTool, .cursor)
        let a = o.attribution(id("/a"))!
        XCTAssertFalse(a.isExact); XCTAssertEqual(a.dominantCategory, .worktree); XCTAssertEqual(a.attributedBytes, 900)
        XCTAssertTrue(a.itemIDs.isEmpty)
        XCTAssertNotNil(o.attribution(tree.rootNodeID))
        XCTAssertNil(o.attribution(id("/prot")))
    }

    func testItemInsideCollapsedPackageMapsToPackage() {
        var t = SyntheticNode.dir("Big.app", flags: [.package, .collapsed]); t.allocatedBytes = 5000
        let tr = MapFix.tree([t])
        let o = DiskMapOverlay.build(tree: tr, items: [Self.item("/synthetic/Big.app/Contents/Cache", bytes: 100)])
        let n = o.attribution(tr.lookup(path: "/synthetic/Big.app")!)!
        XCTAssertFalse(n.isExact); XCTAssertEqual(n.attributedBytes, 100)
    }

    func testCaseAndNFDVariantMaps() {
        let tr = MapFix.tree([.dir("Café", [.file("x", bytes: 10)])])
        let nfd = "/SYNTHETIC/Cafe\u{301}"
        let o = DiskMapOverlay.build(tree: tr, items: [Self.item(nfd, bytes: 10)])
        XCTAssertTrue(o.attribution(tr.lookup(path: "/synthetic/Café")!)!.isExact)
    }

    func testProtectedNodeFlaggedFromTreeNotOverlay() {
        let o = DiskMapOverlay.build(tree: tree, items: [Self.item("/synthetic/prot", bytes: 10)])
        let l = DiskMapLayout.strata(tree: tree, focus: tree.rootNodeID, viewport: LayoutRect(x: 0, y: 0, width: 800, height: 200))
        XCTAssertTrue(l.element(for: id("/prot"))!.isProtected)
        XCTAssertFalse(l.element(for: id("/a"))!.isProtected)
        XCTAssertNotNil(o.attribution(id("/prot")))
    }

    func testDominantTieBreakDeterministic() {
        let items = [Self.item("/synthetic/a/g", bytes: 100, category: .systemJunk, tool: "zeta", id: "1"),
                     Self.item("/synthetic/a/b", bytes: 100, category: .aiToolData, tool: "alpha", id: "2")]
        for order in [items, items.reversed()] {
            let a = DiskMapOverlay.build(tree: tree, items: order).attribution(id("/a"))!
            XCTAssertEqual(a.dominantCategory, .aiToolData)      // earlier in allCases
            XCTAssertEqual(a.dominantTool, "alpha")
        }
    }

    func testAttributedBytesCappedAtNodeBytes() {
        let o = DiskMapOverlay.build(tree: tree, items: [Self.item("/synthetic/a/g", bytes: 5000), Self.item("/synthetic/a", bytes: 5000, id: "z")])
        XCTAssertEqual(o.attribution(id("/a"))!.attributedBytes, tree.node(id("/a")).allocatedBytes)
    }

    func testItemOutsideRootIgnored() {
        let o = DiskMapOverlay.build(tree: tree, items: [Self.item("/elsewhere/x", bytes: 5), Self.item("/synthetic2/x", bytes: 5)])
        XCTAssertEqual(o.unmappedItemCount, 2)
        XCTAssertNil(o.attribution(tree.rootNodeID))
    }

    func testAgeBuckets() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func b(_ days: Double) -> AgeBucket { DiskMapOverlay.ageBucket(now.addingTimeInterval(-days * 86_400), now: now) }
        XCTAssertEqual(b(29.99), .lastMonth); XCTAssertEqual(b(30), .last6Months)
        XCTAssertEqual(b(182.99), .last6Months); XCTAssertEqual(b(183), .lastYear)
        XCTAssertEqual(b(364.99), .lastYear); XCTAssertEqual(b(365), .last3Years)
        XCTAssertEqual(b(1094.99), .last3Years); XCTAssertEqual(b(1095), .older)
        XCTAssertEqual(DiskMapOverlay.ageBucket(nil, now: now), .unknown)
        XCTAssertEqual(b(-5), .lastMonth)
    }
}
