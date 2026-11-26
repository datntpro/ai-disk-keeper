import DiskKeeperCore
import Foundation
import Observation

/// The only path to `CleanupEngine.execute`: review (dry run) → preview → confirm → results.
@MainActor @Observable
public final class CleanupFlowModel {
    public enum Notice: Equatable, Sendable { case refreshedBecauseExpired }

    public enum State {
        case idle
        case planning
        /// The ONLY state from which `confirm()` acts.
        case previewing(CleanupPlan, notice: Notice?)
        case executing(CleanupPlan, CleanupProgress?)
        case finished(CleanupReport, CleanupPlan)
        case failed(String)
    }

    public private(set) var state: State = .idle

    @ObservationIgnored private let engine: any CleanupEngineProtocol
    @ObservationIgnored private var items: [ScanItem] = []
    /// Bumped whenever a plan is requested or abandoned; a late `plan()` result is dropped unless it still matches.
    @ObservationIgnored private var planGeneration = 0
    @ObservationIgnored private var executeTask: Task<CleanupReport, Error>?

    public init(engine: any CleanupEngineProtocol) { self.engine = engine }

    public var isExecuting: Bool { if case .executing = state { return true } else { return false } }
    public var isActive: Bool { if case .idle = state { return false } else { return true } }

    /// idle | failed | finished → planning → previewing.
    public func review(_ newItems: [ScanItem]) async {
        switch state {
        case .idle, .failed, .finished: break
        default: return
        }
        guard !newItems.isEmpty else { return }
        items = newItems
        await makePlan(notice: nil)
    }

    /// previewing → planning → previewing, for the same items. The old plan is simply abandoned (it expires).
    public func recheck() async {
        guard case .previewing = state else { return }
        await makePlan(notice: nil)
    }

    private func makePlan(notice: Notice?) async {
        planGeneration += 1
        let generation = planGeneration
        state = .planning
        let plan = await engine.plan(items)
        // Dismissed (or superseded) while planning: drop the result instead of re-opening the sheet.
        guard generation == planGeneration, case .planning = state else { return }
        state = .previewing(plan, notice: notice)
    }

    /// previewing → executing → finished | failed | previewing(expired). Passes the stored plan by value, unchanged.
    public func confirm() async {
        guard case .previewing(let plan, _) = state, !plan.executableEntries.isEmpty else { return }
        state = .executing(plan, nil)
        let engine = engine
        let planID = plan.id
        let onProgress: @Sendable (CleanupProgress) -> Void = { [weak self] p in
            Task { @MainActor [weak self] in self?.applyProgress(p, planID: planID) }
        }
        let task = Task { try await engine.execute(plan, progress: onProgress) }
        executeTask = task
        let outcome = await task.result
        executeTask = nil
        switch outcome {
        case .success(let report):
            state = .finished(report, plan)
        case .failure(let error):
            await handle(error)
        }
    }

    private func handle(_ error: Error) async {
        switch error as? CleanupError {
        case .planExpired:
            // Never auto-execute: show a fresh preview and make the user confirm again.
            await makePlan(notice: .refreshedBecauseExpired)
        case .auditLogUnavailable(let msg):
            state = .failed(CleanupCopy.auditOpenFailed(msg))
        case .planModified, .unknownPlan, .planAlreadyExecuted:
            assertionFailure("Cleanup plan binding violated: \(error)")
            state = .failed(CleanupCopy.internalError("\(error)"))
        case nil:
            state = .failed(CleanupCopy.genericFailure(error.localizedDescription))
        }
    }

    private func applyProgress(_ p: CleanupProgress, planID: UUID) {
        guard case .executing(let plan, _) = state, plan.id == planID else { return }
        state = .executing(plan, p)
    }

    /// Cancels the run; the engine marks the rest `notAttempted`.
    public func stop() { executeTask?.cancel() }

    /// → idle. Not allowed while executing.
    public func dismiss() {
        guard !isExecuting else { return }
        planGeneration += 1
        state = .idle
        items = []
    }
}
