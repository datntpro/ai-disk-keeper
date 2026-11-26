@testable import DiskKeeperCore
import Foundation
@testable import AIDiskKeeperUI

/// Test double. `index` suspends until the test calls `finish` / `fail`, or the run is cancelled.
actor FakeDiskIndexer: DiskIndexing {
    private var continuation: CheckedContinuation<DiskTree, Error>?
    private(set) var scopes: [DiskIndexer.Scope] = []
    private(set) var cancelCalls = 0
    private var burst: [IndexProgress] = []

    func setProgressBurst(_ p: [IndexProgress]) { burst = p }

    func index(_ scope: DiskIndexer.Scope, progress: (@Sendable (IndexProgress) -> Void)?) async throws -> DiskTree {
        scopes.append(scope)
        for p in burst { progress?(p) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<DiskTree, Error>) in
                if Task.isCancelled { c.resume(throwing: CancellationError()); return }
                continuation = c
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func cancel() {
        cancelCalls += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    var isWaiting: Bool { continuation != nil }

    func finish(_ tree: DiskTree) { continuation?.resume(returning: tree); continuation = nil }
    func fail(_ error: Error) { continuation?.resume(throwing: error); continuation = nil }

    static func tree(_ name: String = "a") -> DiskTree {
        DiskTree._synthetic(.dir("root", [.file(name, bytes: 100)]), rootPath: "/tmp/fixture-root")
    }
}
