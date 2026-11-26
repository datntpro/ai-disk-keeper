import Foundation
import XCTest
@testable import DiskKeeperCore

struct CareTestFailure: Error {}

/// Counts how often a stage body ran.
final class CareCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [CareStage: Int] = [:]
    func hit(_ s: CareStage) { lock.lock(); counts[s, default: 0] += 1; lock.unlock() }
    func count(_ s: CareStage) -> Int { lock.lock(); defer { lock.unlock() }; return counts[s] ?? 0 }
}

/// A scripted stage: delivers `items`, then optionally throws or waits for cancellation.
enum FakeStage {
    static func spec(_ stage: CareStage, modules: [CareModule] = [], needsTree: Bool = false,
                     items: [ScanItem] = [], warnings: [ScanWarning] = [],
                     delay: Duration? = nil, throwAfter: Int? = nil, awaitCancel: Bool = false,
                     artifact: CareArtifact? = nil, counter: CareCallCounter? = nil,
                     onItemsDelivered: (@Sendable () async -> Void)? = nil) -> CareStageSpec {
        CareStageSpec(stage: stage, modules: modules, needsTree: needsTree) { _, sink in
            counter?.hit(stage)
            for w in warnings { await sink.warning(w) }
            for (i, item) in items.enumerated() {
                if let throwAfter, i == throwAfter { throw CareTestFailure() }
                if let delay { try await Task.sleep(for: delay) }
                await sink.item(item)
            }
            if let throwAfter, throwAfter >= items.count { throw CareTestFailure() }
            if let artifact { await sink.artifact(artifact) }
            await onItemsDelivered?()
            if awaitCancel {
                while true { try await Task.sleep(for: .milliseconds(10)) }
            }
        }
    }
}

enum CareKit {
    static func item(_ path: String, tier: RiskTier = .safe, size: Int64 = 100, category: ItemCategory = .aiToolData,
                     tool: ToolID = "claude-code", flags: Set<ItemFlag> = [], rule: String = "t.r") -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: path), displayName: (path as NSString).lastPathComponent, tool: tool,
                 category: category, sizeAllocated: size, sizeLogical: size, fileCount: 1, lastModified: nil,
                 tier: tier, explanation: "x", ruleID: rule, flags: flags)
    }

    /// Collects the whole stream; a timeout cancels the consumer so a hang fails the test instead.
    static func collect(_ stream: AsyncStream<CareScanEvent>, timeout: Double = 30) async -> [CareScanEvent] {
        let collector = Task { () -> [CareScanEvent] in
            var out: [CareScanEvent] = []
            for await e in stream { out.append(e) }
            return out
        }
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            collector.cancel()
        }
        let events = await collector.value
        timer.cancel()
        return events
    }

    static func run(_ stages: [CareStageSpec], history: CareHistoryStore? = nil, fingerprint: String = "fp",
                    clock: @escaping @Sendable () -> Date = { Date() }) async throws -> [CareScanEvent] {
        let c = CareScanCoordinator(stages: stages, history: history, scopeFingerprint: fingerprint, clock: clock)
        return await collect(try await c.scan())
    }

    static func report(_ events: [CareScanEvent]) -> CareReport? {
        switch events.last {
        case .finished(let r), .cancelled(let r): return r
        default: return nil
        }
    }

    /// "stageStarted:rules", "item:rules", "stageFinished:index" … for order assertions.
    static func trace(_ events: [CareScanEvent]) -> [String] {
        events.compactMap {
            switch $0 {
            case .stageStarted(let s): "start:\(s.rawValue)"
            case .stageFinished(let s, _): "finish:\(s.rawValue)"
            case .stageFailed(let s, _): "fail:\(s.rawValue)"
            case .stageSkipped(let s, let r): "skip:\(s.rawValue):\(r.rawValue)"
            case .item(let s, _): "item:\(s.rawValue)"
            case .finished: "finished"
            case .cancelled: "cancelled"
            default: nil
            }
        }
    }

    static func syntheticTree() -> DiskTree {
        DiskTree._synthetic(.dir("", [.file("a.bin", bytes: 10)]), rootPath: "/care-fixture")
    }
}
