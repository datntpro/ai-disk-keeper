import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

/// Shared helpers: indexers over fixtures only (never the real home).
enum IndexTest {
    static func indexer(_ fx: FixtureHome, options: IndexOptions = .init()) throws -> DiskIndexer {
        DiskIndexer(environment: fx.env,
                    pathGuard: try ProtectedPaths(homeDirectory: fx.home, temporaryDirectory: fx.tempDir),
                    options: options)
    }

    static func index(_ fx: FixtureHome, options: IndexOptions = .init()) async throws -> DiskTree {
        try await indexer(fx, options: options).index(.home)
    }

    static func sizer(_ path: String) throws -> SizeReport {
        try FileSizer().sizeBlocking(of: URL(fileURLWithPath: path))
    }

    /// Every node with its absolute path (skips smallItems).
    static func all(_ t: DiskTree) -> [(DiskNodeID, DiskNode, String)] {
        (0..<t.nodeCount).map { i in
            let id = DiskNodeID(raw: Int32(i))
            return (id, t.node(id), t.path(of: id))
        }
    }

    static func find(_ t: DiskTree, _ path: String) -> DiskNode? {
        all(t).first { $0.2 == path && !$0.1.flags.contains(.smallItems) }?.1
    }

    static func bytes(_ n: Int) -> Int { n }
    static let MiB = 1 << 20
}
