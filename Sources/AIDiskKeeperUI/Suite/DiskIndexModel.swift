import DiskKeeperCore
import Foundation
import Observation

/// The one disk index for Map, Large & Old and Duplicates. Nobody else creates a `DiskIndexer`.
/// Never starts by itself: the first build is always a user click (see `IndexGateView`).
@MainActor @Observable
public final class DiskIndexModel {
    public enum Phase: Equatable { case idle, indexing, ready, cancelled, failed(String) }

    public private(set) var phase: Phase = .idle
    public private(set) var progress: IndexProgress?
    /// The last complete tree; kept while re-indexing and after a cancel or failure.
    public private(set) var tree: DiskTree?
    /// +1 per new tree; screens recompute when it changes.
    public private(set) var generation = 0
    public private(set) var builtAt: Date?
    public private(set) var scope: DiskIndexer.Scope = .home
    public var fullDiskAvailable: Bool { fullDiskAccess() }

    @ObservationIgnored private let makeIndexer: @Sendable () throws -> any DiskIndexing
    @ObservationIgnored private let fullDiskAccess: @MainActor () -> Bool
    @ObservationIgnored private let minProgressInterval: Duration
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var indexer: (any DiskIndexing)?
    @ObservationIgnored private var lastProgressAt: ContinuousClock.Instant?
    /// How many progress updates reached `progress` (tests check coalescing).
    @ObservationIgnored private(set) var appliedProgressCount = 0

    public init(makeIndexer: @escaping @Sendable () throws -> any DiskIndexing,
                fullDiskAccess: @escaping @MainActor () -> Bool,
                minProgressInterval: Duration = .milliseconds(100)) {
        self.makeIndexer = makeIndexer
        self.fullDiskAccess = fullDiskAccess
        self.minProgressInterval = minProgressInterval
    }

    /// Cancels a running build first. `.fullDisk` is refused (nothing changes) unless Full Disk Access is granted.
    public func start(_ scope: DiskIndexer.Scope) {
        if scope == .fullDisk, !fullDiskAvailable { return }
        abandonCurrent()
        self.scope = scope
        phase = .indexing
        progress = nil
        lastProgressAt = nil
        let id = runID
        let make = makeIndexer
        task = Task { [weak self] in
            do {
                // Building the guard loads rule JSON: keep it off the main actor.
                let indexer = try await Task.detached { try make() }.value
                guard let model = self, model.runID == id else { return }
                model.indexer = indexer
                let tree = try await indexer.index(scope) { [weak model] p in
                    Task { @MainActor in model?.receive(p, run: id) }
                }
                model.finish(tree, run: id)
            } catch is CancellationError {
                self?.markCancelled(run: id)
            } catch {
                self?.fail(error, run: id)
            }
        }
    }

    public func cancel() {
        guard phase == .indexing else { return }
        abandonCurrent()
        phase = .cancelled
        progress = nil
    }

    /// Invalidates the running build: its late result is dropped, and the indexer is told to stop.
    private func abandonCurrent() {
        runID += 1
        task?.cancel()
        task = nil
        if let indexer { Task { await indexer.cancel() } }
        indexer = nil
    }

    private func receive(_ p: IndexProgress, run: Int) {
        guard run == runID, phase == .indexing else { return }
        let now = ContinuousClock.now
        if let last = lastProgressAt, now - last < minProgressInterval { return }
        lastProgressAt = now
        appliedProgressCount += 1
        progress = p
    }

    private func finish(_ tree: DiskTree, run: Int) {
        guard run == runID else { return }
        self.tree = tree
        generation += 1
        builtAt = Date()
        progress = nil
        indexer = nil
        phase = .ready
    }

    private func markCancelled(run: Int) {
        guard run == runID else { return }
        progress = nil
        indexer = nil
        phase = .cancelled
    }

    private func fail(_ error: Error, run: Int) {
        guard run == runID else { return }
        progress = nil
        indexer = nil
        phase = .failed(String(describing: error))
    }
}
