import XCTest
@testable import DiskKeeperCore
import protocol DiskKeeperCore.Scanner

private struct VirtualScanner: Scanner {
    let id = "virt"
    let virtualNamespace: String?
    let items: [ScanItem]
    func scan(context: ScanContext, sink: ScanSink) async throws { for i in items { await sink.item(i) } }
}

final class VirtualItemPathTests: XCTestCase {
    func testBuildAndParse() throws {
        let p = try XCTUnwrap(VirtualItemPath.build(namespace: "docker", target: "orbstack", kind: "image", id: ToolFixtures.imageID))
        XCTAssertEqual(p, "/.aidiskkeeper-virtual/docker/orbstack/image/" + ToolFixtures.imageID)
        XCTAssertEqual(VirtualItemPath.parse(p), .init(namespace: "docker", target: "orbstack", kind: "image", id: ToolFixtures.imageID))
        XCTAssertNil(VirtualItemPath.build(namespace: "a/b", target: "t", kind: "k", id: "i"))
        XCTAssertNil(VirtualItemPath.build(namespace: "a", target: "..", kind: "k", id: "i"))
        XCTAssertNil(VirtualItemPath.parse("/.aidiskkeeper-virtual/a/b/c"))
        XCTAssertNil(VirtualItemPath.parse("/.aidiskkeeper-virtual/a/b/c/d/e"))
        XCTAssertNil(VirtualItemPath.parse("/Users/x/a/b/c/d"))
        XCTAssertTrue(ToolFixtures.virtualItem().isVirtual)
    }

    private func scan(_ scanner: VirtualScanner) async throws -> [ScanItem] {
        let fixture = try FixtureHome()
        let rules = try TemporaryDirectory()
        let engine = try ScanEngine.makeDefault(environment: fixture.env, bundledRulesDirectory: rules.url,
                                                extraScanners: [scanner], maxConcurrentSizing: 2)
        return EngineKit.items(await EngineKit.collect(try await engine.scan()))
    }

    func testOwnNamespaceIsAccepted() async throws {
        let items = try await scan(VirtualScanner(virtualNamespace: "adktest", items: [ToolFixtures.virtualItem()]))
        XCTAssertEqual(items.count, 1)
    }

    func testNoNamespaceOrAnotherNamespaceIsDropped() async throws {
        let none = try await scan(VirtualScanner(virtualNamespace: nil, items: [ToolFixtures.virtualItem()]))
        XCTAssertTrue(none.isEmpty)
        let other = try await scan(VirtualScanner(virtualNamespace: "docker", items: [ToolFixtures.virtualItem()]))
        XCTAssertTrue(other.isEmpty)
    }

    func testVirtualItemWithTrashIsDropped() async throws {
        let trash = ToolFixtures.virtualItem(method: .trash)
        let items = try await scan(VirtualScanner(virtualNamespace: "adktest", items: [trash]))
        XCTAssertTrue(items.isEmpty)
    }

    func testReportOnlyVirtualItemIsAccepted() async throws {
        let items = try await scan(VirtualScanner(virtualNamespace: "adktest", items: [ToolFixtures.virtualItem(method: CleanupMethod.none)]))
        XCTAssertEqual(items.count, 1)
    }
}
