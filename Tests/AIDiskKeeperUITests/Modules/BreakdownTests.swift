import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

final class BreakdownTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("adk-bd-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("main/.git/worktrees/wt"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("wt"), withIntermediateDirectories: true)
        try "gitdir: \(root.path)/main/.git/worktrees/wt".write(to: root.appendingPathComponent("wt/.git"), atomically: true, encoding: .utf8)
        ProjectKeyResolver.shared.reset()
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root); ProjectKeyResolver.shared.reset() }

    private func item(_ name: String, tool: ToolID = .claudeCode, tier: RiskTier = .safe, size: Int64 = 100,
                      project: ProjectRef? = nil) -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: "/tmp/fixture/\(tool.rawValue)/\(name)"), displayName: name, tool: tool,
                 category: .aiToolData, project: project, sizeAllocated: size, sizeLogical: size, fileCount: 1,
                 lastModified: nil, tier: tier, explanation: "x", ruleID: "r")
    }
    private var mainRef: ProjectRef { ProjectRef(rootURL: root.appendingPathComponent("main")) }
    private var wtRef: ProjectRef { ProjectRef(rootURL: root.appendingPathComponent("wt")) }

    private var sample: [ScanItem] {
        [item("a", size: 300, project: mainRef), item("b", tool: .cursor, tier: .review, size: 200, project: wtRef),
         item("c", tier: .keep, size: 50, project: ProjectRef(id: "name:x", displayName: "x")), item("d", size: 10)]
    }

    func testPerProjectTotalEqualsSumOfItemsAndWorktreeMerged() {
        let by = ScanTotals.byProject(sample)
        let mainID = mainRef.id
        XCTAssertEqual(by[mainID]?.totals.allocatedBytes, 500)
        XCTAssertEqual(by[mainID]?.totals.itemCount, 2)
        XCTAssertEqual(by["name:x"]?.totals.allocatedBytes, 50)
        XCTAssertEqual(by[ItemQuery.noProject]?.totals.allocatedBytes, 10)
        XCTAssertEqual(by.values.reduce(0) { $0 + $1.totals.allocatedBytes }, sample.reduce(0) { $0 + $1.sizeAllocated })
    }

    func testQueryFiltersAndWithScopeTierSearch() {
        let items = sample
        XCTAssertEqual(ItemQuery(scope: .overview, projectID: mainRef.id).apply(to: items).count, 2)
        XCTAssertEqual(ItemQuery(scope: .overview, projectID: ItemQuery.noProject).apply(to: items).map(\.displayName), ["d"])
        XCTAssertEqual(ItemQuery(scope: .overview, toolFilter: .cursor).apply(to: items).map(\.displayName), ["b"])
        XCTAssertEqual(ItemQuery(scope: .tool(.claudeCode), projectID: mainRef.id).apply(to: items).map(\.displayName), ["a"])
        XCTAssertEqual(ItemQuery(scope: .overview, tiers: [.safe], projectID: mainRef.id).apply(to: items).map(\.displayName), ["a"])
        XCTAssertEqual(ItemQuery(scope: .overview, searchText: "b", projectID: mainRef.id, toolFilter: .cursor).apply(to: items).count, 1)
        var q = ItemQuery(scope: .overview, projectID: mainRef.id, toolFilter: .cursor)
        q.projectID = nil; q.toolFilter = nil
        XCTAssertEqual(q.apply(to: items).count, 4)
    }

    func testTopNPlusOtherSumsToTotal() {
        let items = (0..<12).map { item("i\($0)", tool: ToolID(rawValue: "t\($0)"), size: Int64(($0 + 1) * 10)) }
        let rows = ProjectBreakdown.byTool(items, limit: 8)
        XCTAssertEqual(rows.count, 9)
        XCTAssertNil(rows.last?.id)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.total }, items.reduce(0) { $0 + $1.sizeAllocated })
        XCTAssertEqual(rows.first?.total, 120)
    }

    func testRowTiersAndAccessibilityLabel() {
        let rows = ProjectBreakdown.byProject(sample)
        let main = rows.first { $0.id == mainRef.id }
        XCTAssertEqual(main?.safe, 300)
        XCTAssertEqual(main?.review, 200)
        let label = main?.accessibilityLabel ?? ""
        XCTAssertTrue(label.contains(Formatting.bytes(500)))
        XCTAssertTrue(label.contains(Formatting.bytes(300)))
        XCTAssertFalse(label.isEmpty)
        XCTAssertNotNil(rows.first { $0.id == ItemQuery.noProject })
    }

    func testSameNamedProjectsGetDistinctRowsAndLabels() throws {
        let a = ProjectRef(id: "/work/api", displayName: "api"), b = ProjectRef(id: "/oss/api", displayName: "api")
        let rows = ProjectBreakdown.byProject([item("x", size: 300, project: a), item("y", size: 100, project: b)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.chartID)).count, 2)
        XCTAssertEqual(Set(rows.map(\.label)).count, 2)
        XCTAssertTrue(rows[0].label.contains("work"))
        XCTAssertTrue(rows[1].label.contains("oss"))
        // Each row is selectable by its own id.
        XCTAssertEqual(ItemQuery(scope: .overview, projectID: "/oss/api").apply(to: [item("x", size: 300, project: a), item("y", size: 100, project: b)]).map(\.displayName), ["y"])
    }

    func testUniqueNamesKeepPlainLabels() {
        let rows = ProjectBreakdown.byTool([item("a"), item("b", tool: .cursor)])
        XCTAssertEqual(rows.map(\.label), rows.map(\.name))
    }

    func testScopeChangeClearsChartFilters() {
        var q = ItemQuery(scope: .module(.aiTools), projectID: "/p", toolFilter: .cursor)
        q.setScope(.module(.aiTools))
        XCTAssertEqual(q.projectID, "/p")
        q.setScope(.module(.worktrees))
        XCTAssertNil(q.projectID)
        XCTAssertNil(q.toolFilter)
        XCTAssertEqual(q.scope, .module(.worktrees))
    }
}
