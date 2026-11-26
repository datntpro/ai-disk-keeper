import DiskKeeperCore
import Foundation
import XCTest
@testable import DiskKeeperCore
@testable import AIDiskKeeperUI

private final class OneShot: @unchecked Sendable {
    let fake: FakeDiskIndexer
    init(_ f: FakeDiskIndexer) { fake = f }
}

enum DiskMapFixtures {
    static let tool = ToolID.claudeCode.rawValue

    /// /tmp/fixture: claude-code{cache{a,b}, sessions{x}, notes.txt}, Movies{m1,m2}, .ssh (protected), loose.bin
    static func tree() -> DiskTree {
        let spec = SyntheticNode.dir("r", [
            .dir(tool, [
                .dir("cache", [.file("a", bytes: 400), .file("b", bytes: 100)]),
                .dir("sessions", [.dir("x", [.file("x1", bytes: 200)])]),
                .file("notes.txt", bytes: 50),
            ]),
            .dir("Movies", [.file("m1", bytes: 300), .file("m2", bytes: 200)]),
            .dir(".ssh", flags: [.protected], [.file("k", bytes: 10, flags: [.protected])]),
            .file("loose.bin", bytes: 150),
        ])
        return DiskTree._synthetic(spec, rootPath: "/tmp/fixture")
    }

    /// One big child plus 300 tiny ones: narrow tails merge into an aggregate.
    static func aggregateTree() -> DiskTree {
        var kids: [SyntheticNode] = [.file("big", bytes: 1_000_000)]
        for i in 0..<300 { kids.append(.file("t\(i)", bytes: 10)) }
        return DiskTree._synthetic(.dir("r", kids), rootPath: "/tmp/fixture")
    }

    static func id(_ path: String, in tree: DiskTree) -> DiskNodeID {
        tree.lookup(path: "/tmp/fixture/" + path)!
    }
}

@MainActor
enum DiskMapHarness {
    static func index(with tree: DiskTree, fda: Bool = false) async -> (DiskIndexModel, FakeDiskIndexer) {
        let fake = FakeDiskIndexer()
        let box = OneShot(fake)
        let index = DiskIndexModel(makeIndexer: { box.fake }, fullDiskAccess: { fda }, minProgressInterval: .zero)
        index.start(.home)
        for _ in 0..<600 { if await fake.isWaiting { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        await fake.finish(tree)
        for _ in 0..<600 { if index.phase == .ready { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        return (index, fake)
    }

    static func model(tree: DiskTree, items: [ScanItem] = [], size: CGSize = CGSize(width: 800, height: 400),
                      mode: DiskMapModel.Mode = .strata,
                      announce: @escaping @MainActor (String) -> Void = { _ in }) async -> DiskMapModel {
        let (index, _) = await index(with: tree)
        let m = DiskMapModel(index: index, scanItems: { items }, debounce: .milliseconds(1),
                             tooltipDelay: .milliseconds(5), announce: announce)
        m.setMode(mode)
        m.treeChanged()
        m.viewportChanged(size)
        await m.waitForLayout()
        await m.waitForOverlay()
        return m
    }

    /// The centre of the element drawn for `node`.
    static func center(of node: DiskNodeID, in m: DiskMapModel) -> CGPoint {
        let r = m.layout!.element(for: node)!.rect
        return CGPoint(x: r.x + r.width / 2, y: r.y + r.height / 2)
    }
}
