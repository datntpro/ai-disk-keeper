import DiskKeeperCore
import Foundation
import Observation
import SwiftUI

/// The Care Scan seam, so tests drive the model with a scripted fake. `CareScanCoordinator` is the real one.
protocol CareScanning: Sendable {
    func scan() async throws -> AsyncStream<CareScanEvent>
    func cancel() async
}

extension CareScanCoordinator: CareScanning {}

enum CareStageState: Equatable {
    case pending
    case running(Double?)
    case done, failed, skipped
}

/// The Overview's one model: it runs the Care Scan, shows it live, and hands each stage's result to the screen that
/// owns it (the rule events to `ScanViewModel`, the Large & Old / Duplicates reports to their models). Read-only:
/// the only way out to a cleanup is `cleanSafeOnly`, which opens the dry-run sheet and nothing else.
@MainActor @Observable
final class CareScanModel {
    enum Phase: Equatable {
        case before, scanning, results
        /// Cancelled with partial results.
        case stopped
    }

    enum PrimaryAction: Equatable {
        case scan, stop
        /// Reviewable bytes (Safe + Review).
        case review(Int64)
    }

    private(set) var phase: Phase = .before
    private(set) var stages: [CareStage] = []
    private(set) var stageState: [CareStage: CareStageState] = [:]
    private(set) var stageFailures: [CareStage: ScanWarning] = [:]
    private(set) var summaries: [CareModule: ModuleSummary] = [:]
    private(set) var totals: CareTotals?
    private(set) var growth: CareGrowth?
    /// The three biggest items across all stages, after the cross-stage dedupe.
    private(set) var biggestWins: [ScanItem] = []
    private(set) var warnings: [ScanWarning] = []
    private(set) var lastFinishedAt: Date?
    /// Distinct duplicate groups seen so far (a tile caption).
    private(set) var duplicateGroupCount = 0
    /// Bytes found so far (a running total shown while scanning).
    private(set) var foundBytes: Int64 = 0

    let scan: ScanViewModel
    let index: DiskIndexModel

    @ObservationIgnored private let makeCoordinator: @Sendable (DiskIndexer.Scope) throws -> any CareScanning
    @ObservationIgnored private let duplicates: @MainActor () -> DuplicatesModel?
    @ObservationIgnored private let largeOld: @MainActor () -> LargeOldModel?
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private var coordinator: (any CareScanning)?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var ruleEvents: AsyncStream<ScanEvent>.Continuation?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var candidates: [ScanItem] = []
    @ObservationIgnored private var groupIDs = Set<String>()

    /// `makeCoordinator` runs off the main actor (it loads rule JSON); it gets the index scope chosen at start.
    init(makeCoordinator: @escaping @Sendable (DiskIndexer.Scope) throws -> any CareScanning,
         scan: ScanViewModel, index: DiskIndexModel,
         duplicates: @escaping @MainActor () -> DuplicatesModel?, largeOld: @escaping @MainActor () -> LargeOldModel?,
         announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }) {
        self.makeCoordinator = makeCoordinator
        self.scan = scan
        self.index = index
        self.duplicates = duplicates
        self.largeOld = largeOld
        self.announce = announce
    }

    // MARK: Derived

    var isBusy: Bool { phase == .scanning }

    var reviewableBytes: Int64 { totals.map { $0.safeBytes + $0.reviewBytes } ?? 0 }

    var primaryAction: PrimaryAction {
        switch phase {
        case .scanning: .stop
        case .results: .review(reviewableBytes)
        case .before, .stopped: .scan
        }
    }

    /// Items "Clean Safe only…" would open: rule-stage items that are Safe and bulk-selectable.
    var safeBulkItems: [ScanItem] { scan.items.filter { $0.isBulkSelectable && $0.tier == .safe } }
    var safeBulkBytes: Int64 { safeBulkItems.reduce(0) { $0 + $1.sizeAllocated } }

    /// 0…1 over the stages (a running stage counts by its own progress when it has one).
    var progressFraction: Double {
        guard !stages.isEmpty else { return 0 }
        let sum = stages.reduce(0.0) { acc, stage in
            switch stageState[stage] ?? .pending {
            case .done, .failed, .skipped: acc + 1
            case .running(let p): acc + (p ?? 0)
            case .pending: acc
            }
        }
        return min(1, sum / Double(stages.count))
    }

    static func stage(for module: CareModule) -> CareStage {
        switch module {
        case .aiTools, .worktrees, .modelsDocker, .systemJunk: .rules
        case .largeOld: .largeOld
        case .duplicates: .duplicates
        case .apps: .apps
        case .startup: .startup
        }
    }

    /// The chips to draw: a module shows if its screen is enabled or its stage is part of this scan.
    func visibleChips(enabled: Set<ModuleID> = ModuleRegistry.enabledIDs) -> [CareModule] {
        CareModule.allCases.filter { module in
            stages.contains(Self.stage(for: module)) || OverviewTarget.moduleID(for: module).map(enabled.contains) ?? true
        }
    }

    func chipState(_ module: CareModule) -> CareStageState {
        guard phase != .before else { return .pending }
        return stageState[Self.stage(for: module)] ?? .pending
    }

    /// Growth line text, or nil below the ±100 MB threshold.
    var growthLine: String? {
        guard let growth, abs(growth.aiToolsDelta) >= Self.growthThreshold else { return nil }
        let bytes = Formatting.bytes(abs(growth.aiToolsDelta))
        return growth.aiToolsDelta > 0 ? OverviewCopy.growthUp(bytes) : OverviewCopy.growthDown(bytes)
    }

    static let growthThreshold: Int64 = 100_000_000

    // MARK: Run

    func start() {
        guard phase != .scanning else { return }
        reset()
        phase = .scanning
        let scope: DiskIndexer.Scope = index.scope == .fullDisk && index.fullDiskAvailable ? .fullDisk : .home
        let make = makeCoordinator
        runTask = Task { [weak self] in
            do {
                // Building the stages loads rule JSON: keep it off the main actor.
                let coordinator = try await Task.detached { try make(scope) }.value
                guard let self else { return }
                if self.stopRequested { self.endWithoutResults(); return }
                self.coordinator = coordinator
                let stream = try await coordinator.scan()
                // A Stop that landed while `scan()` was being awaited hit an idle coordinator and was ignored.
                if self.stopRequested { await coordinator.cancel() }
                for await event in stream { self.apply(event) }
                if self.phase == .scanning { self.endWithoutResults() }
            } catch {
                guard let self else { return }
                self.warnings.append(ScanWarning(kind: .scannerFailed, message: String(describing: error),
                                                 code: .scannerFailed(scannerID: "care-scan")))
                self.endWithoutResults()
            }
        }
    }

    /// Asks the scan to stop; the partial results are kept (`phase == .stopped`).
    func stop() {
        guard phase == .scanning else { return }
        stopRequested = true
        if let coordinator { Task { await coordinator.cancel() } }
    }

    private func reset() {
        stopRequested = false
        coordinator = nil
        stages = []
        stageState = [:]
        stageFailures = [:]
        summaries = [:]
        totals = nil
        growth = nil
        biggestWins = []
        warnings = []
        candidates = []
        groupIDs = []
        duplicateGroupCount = 0
        foundBytes = 0
    }

    private func endWithoutResults() {
        ruleEvents?.finish()
        ruleEvents = nil
        coordinator = nil
        runTask = nil
        phase = .stopped
    }

    // MARK: Events

    func apply(_ event: CareScanEvent) {
        switch event {
        case .started(_, let all, _):
            stages = all
            stageState = Dictionary(uniqueKeysWithValues: all.map { ($0, CareStageState.pending) })
            let (stream, continuation) = AsyncStream.makeStream(of: ScanEvent.self, bufferingPolicy: .unbounded)
            ruleEvents = continuation
            let coordinator = coordinator
            scan.consume(stream) { await coordinator?.cancel() }
        case .stageStarted(let stage):
            stageState[stage] = .running(nil)
        case .stageProgress(let stage, let p):
            if case .running = stageState[stage] { stageState[stage] = .running(p) }
        case .scanEvent(let stage, let e):
            if stage == .rules { ruleEvents?.yield(e) }
        case .item(_, let item):
            note(item)
        case .warning(_, let w):
            warnings.append(w)
        case .artifact(let artifact):
            adopt(artifact)
        case .stageFinished(let stage, let sums):
            stageState[stage] = .done
            for s in sums { summaries[s.module] = s }
        case .stageFailed(let stage, let w):
            stageState[stage] = .failed
            stageFailures[stage] = w
        case .stageSkipped(let stage, _):
            stageState[stage] = .skipped
        case .finished(let report):
            finish(report, cancelled: false)
        case .cancelled(let report):
            finish(report, cancelled: true)
        }
    }

    private func note(_ item: ScanItem) {
        let counted = !(item.category == .duplicate && (item.flags.contains(.suggestedKeeper) || item.flags.contains(.sharedStorage)))
        guard counted else { return }
        foundBytes += item.sizeAllocated
        if item.category == .duplicate, let g = item.groupID, groupIDs.insert(g).inserted { duplicateGroupCount = groupIDs.count }
        candidates.append(item)
        if candidates.count > 200 {
            candidates = Array(candidates.sorted { $0.sizeAllocated > $1.sizeAllocated }.prefix(60))
        }
        biggestWins = BiggestWins.top(candidates)
    }

    private func adopt(_ artifact: CareArtifact) {
        switch artifact {
        case .largeFiles(let report): largeOld()?.adopt(report, generation: index.generation)
        case .duplicates(let report): duplicates()?.adopt(report, generation: index.generation)
        case .tree, .apps: break   // the index stage built through `DiskIndexModel.build`, so Disk Map already has it
        }
    }

    private func finish(_ report: CareReport, cancelled: Bool) {
        summaries = report.summaries
        totals = report.totals
        growth = report.growth
        warnings = report.warnings
        lastFinishedAt = report.finishedAt
        for stage in report.failedStages where stageState[stage] != .failed { stageState[stage] = .failed }
        biggestWins = BiggestWins.top(candidates)
        ruleEvents?.finish()
        ruleEvents = nil
        coordinator = nil
        runTask = nil
        phase = cancelled ? .stopped : .results
        if cancelled {
            announce(loc("status.stopped", "Scan stopped. Results are partial."))
        } else {
            announce(OverviewCopy.finishedAnnouncement(safe: Formatting.bytes(report.totals.safeBytes),
                                                       review: Formatting.bytes(report.totals.reviewBytes)))
        }
    }

    // MARK: Cleanup

    /// Pre-selects the Safe, bulk-selectable rule items and opens the dry-run sheet. Never Review or Keep; nothing
    /// executes until the sheet's `confirm()`.
    func cleanSafeOnly(using coordinator: CleanupCoordinator, selection: SelectionModel) {
        selection.deselectAll()
        let safe = safeBulkItems
        guard !safe.isEmpty else { return }
        selection.selectAllSafe(in: safe)
        let scan = scan
        coordinator.review(selection.selectedItems(in: safe)) { [weak self] trashed in
            self?.forget(trashed)
            scan.removeItems(trashed)
            selection.deselectAll()
        }
    }

    /// What moved to the Trash no longer counts in the hero numbers.
    private func forget(_ trashed: Set<ScanItem.ID>) {
        guard var t = totals else { return }
        for item in scan.items where trashed.contains(item.id) {
            switch item.tier {
            case .safe: t.safeBytes = max(0, t.safeBytes - item.sizeAllocated)
            case .review: t.reviewBytes = max(0, t.reviewBytes - item.sizeAllocated)
            case .keep: t.keepBytes = max(0, t.keepBytes - item.sizeAllocated)
            }
        }
        totals = t
        candidates.removeAll { trashed.contains($0.id) }
        biggestWins = BiggestWins.top(candidates)
    }
}
