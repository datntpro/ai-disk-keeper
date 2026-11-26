import Foundation

public enum CareScanError: Error, Equatable { case alreadyRunning }

/// Runs the Care Scan stages one after another (never in parallel, so disk I/O stays predictable) and turns what
/// they report into one ordered, cancellable event stream plus per-module summaries and growth.
///
/// Read-only: it has no selection concept and no cleanup API. The only thing it writes is one snapshot in the
/// app's own history file after a completed scan. See docs/care-scan.md.
public actor CareScanCoordinator {
    private let specs: [CareStageSpec]
    private let history: CareHistoryStore?
    private let scopeFingerprint: String
    private let clock: @Sendable () -> Date
    private let progressInterval: Duration

    private var runTask: Task<Void, Never>?
    private var stageTask: Task<Void, Error>?
    private var continuation: AsyncStream<CareScanEvent>.Continuation?
    private var generation = 0
    private var terminated = false
    private var cancelRequested = false

    private var tally = CareTally()
    private var warnings: [ScanWarning] = []
    private var failedStages: [CareStage] = []
    private var tree: DiskTree?
    private var lastProgressAt: ContinuousClock.Instant?
    private var startedAt = Date()
    private let physicalPaths = PhysicalPathResolver()

    /// `stages` may be given in any order; they always run in `CareStage.allCases` order.
    public init(stages: [CareStageSpec], history: CareHistoryStore?, scopeFingerprint: String,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        var byStage: [CareStage: CareStageSpec] = [:]
        for s in stages where byStage[s.stage] == nil { byStage[s.stage] = s }
        self.specs = CareStage.allCases.compactMap { byStage[$0] }
        self.history = history
        self.scopeFingerprint = scopeFingerprint
        self.clock = clock
        self.progressInterval = .milliseconds(100)
    }

    public var isRunning: Bool { runTask != nil }

    /// Starts a scan. Throws `.alreadyRunning` if one is in progress. The stream is unbounded; terminating it
    /// (the consumer cancels its `for await` task or drops the stream) cancels the scan. Single consumer.
    public func scan() throws -> AsyncStream<CareScanEvent> {
        guard runTask == nil else { throw CareScanError.alreadyRunning }
        let (stream, continuation) = AsyncStream.makeStream(of: CareScanEvent.self, bufferingPolicy: .unbounded)
        generation += 1
        let gen = generation
        continuation.onTermination = { @Sendable [self] _ in
            Task { await self.cancel(generation: gen) }
        }
        self.continuation = continuation
        tally = CareTally()
        warnings = []
        failedStages = []
        tree = nil
        lastProgressAt = nil
        terminated = false
        cancelRequested = false
        startedAt = clock()
        runTask = Task { await self.run(generation: gen) }
        return stream
    }

    /// Idempotent. Safe to call when idle.
    public func cancel() { cancel(generation: generation) }

    private func cancel(generation gen: Int) {
        guard gen == generation, runTask != nil, !terminated else { return }
        cancelRequested = true
        stageTask?.cancel()
        runTask?.cancel()
    }

    // MARK: Run

    private func run(generation gen: Int) async {
        let id = UUID()
        yield(.started(id: id, stages: specs.map(\.stage), at: startedAt), gen)
        for spec in specs {
            if cancelRequested { break }
            if spec.needsTree, tree == nil {
                // The index stage failed (or was not given): there is nothing to scan. A user cancel ends the loop above.
                yield(.stageSkipped(spec.stage, reason: .needsTree), gen)
                continue
            }
            await runStage(spec, generation: gen)
        }
        finish(id: id, generation: gen)
    }

    private func runStage(_ spec: CareStageSpec, generation gen: Int) async {
        let stage = spec.stage
        lastProgressAt = nil
        tally.begin(stage, modules: spec.modules)
        yield(.stageStarted(stage), gen)

        let input = CareStageInput(tree: tree, now: clock())
        let resolver = physicalPaths
        let sink = CareStageSink(
            item: { [self] item in
                // Path resolution runs on the stage's task, not on the actor.
                let physical = await resolver.physical(item.path)
                await self.accept(item, physical: physical, stage: stage, generation: gen)
            },
            warning: { [self] w in await self.accept(w, stage: stage, generation: gen) },
            progress: { [self] p in await self.progress(p, stage: stage, generation: gen) },
            scanEvent: { [self] e in await self.forward(e, stage: stage, generation: gen) },
            artifact: { [self] a in await self.accept(a, generation: gen) })
        let task = Task { try await spec.run(input, sink) }
        stageTask = task
        let outcome = await task.result
        stageTask = nil
        if cancelRequested { return }
        switch outcome {
        case .success:
            yield(.stageFinished(stage, tally.stageSummary(stage)), gen)
        case .failure(let error):
            let warning = ScanWarning(kind: .scannerFailed, message: "\(stage.rawValue): \(error)",
                                      code: .scannerFailed(scannerID: stage.rawValue))
            warnings.append(warning)
            failedStages.append(stage)
            yield(.stageFailed(stage, warning), gen)
        }
    }

    private func isOpen(_ gen: Int) -> Bool { gen == generation && !terminated && !cancelRequested }

    private func yield(_ event: CareScanEvent, _ gen: Int) {
        guard gen == generation, !terminated else { return }
        continuation?.yield(event)
    }

    private func accept(_ item: ScanItem, physical: String, stage: CareStage, generation gen: Int) {
        guard isOpen(gen) else { return }
        tally.add(item, physical: physical, stage: stage)
        yield(.item(stage, item), gen)
    }

    private func accept(_ warning: ScanWarning, stage: CareStage, generation gen: Int) {
        guard isOpen(gen) else { return }
        warnings.append(warning)
        yield(.warning(stage, warning), gen)
    }

    private func accept(_ artifact: CareArtifact, generation gen: Int) {
        guard isOpen(gen) else { return }
        if case .tree(let t) = artifact { tree = t }
        yield(.artifact(artifact), gen)
    }

    private func forward(_ event: ScanEvent, stage: CareStage, generation gen: Int) {
        guard isOpen(gen) else { return }
        yield(.scanEvent(stage, event), gen)
    }

    /// At most one progress event per `progressInterval` per stage; 1.0 always passes.
    private func progress(_ value: Double?, stage: CareStage, generation gen: Int) {
        guard isOpen(gen) else { return }
        let now = ContinuousClock.now
        if let last = lastProgressAt, now - last < progressInterval, value != 1 { return }
        lastProgressAt = now
        yield(.stageProgress(stage, value.map { min(1, max(0, $0)) }), gen)
    }

    private func finish(id: UUID, generation gen: Int) {
        guard gen == generation, !terminated else { return }
        let wasCancelled = cancelRequested
        let finishedAt = clock()

        var growth: CareGrowth?
        if !wasCancelled, !failedStages.contains(.rules), let history {
            let perModule = Dictionary(uniqueKeysWithValues: tally.summaries.map { ($0.key.rawValue, $0.value.totalBytes) })
            let snapshot = CareSnapshot(finishedAt: finishedAt, scopeFingerprint: scopeFingerprint,
                                        perTool: tally.perTool, perModule: perModule)
            if let previous = history.load().last(where: { $0.schemaVersion == 1 && $0.scopeFingerprint == scopeFingerprint }) {
                growth = Self.growth(from: previous, to: snapshot)
            }
            do { try history.append(snapshot) } catch {
                warnings.append(ScanWarning(kind: .other, path: history.fileURL.path,
                                            message: "Care Scan history could not be saved: \(error.localizedDescription)",
                                            code: .scannerFailed(scannerID: "care-history")))
            }
        }
        let report = CareReport(id: id, startedAt: startedAt, finishedAt: finishedAt, wasCancelled: wasCancelled,
                                summaries: tally.summaries, totals: tally.totals, warnings: warnings,
                                failedStages: failedStages, growth: growth)
        continuation?.yield(wasCancelled ? .cancelled(report) : .finished(report))
        terminated = true
        continuation?.finish()
        continuation = nil
        runTask = nil
        stageTask = nil
        tally = CareTally(); warnings = []; tree = nil
    }

    static func growth(from previous: CareSnapshot, to current: CareSnapshot) -> CareGrowth {
        var perTool: [ToolID: Int64] = [:]
        for key in Set(previous.perTool.keys).union(current.perTool.keys) {
            perTool[ToolID(rawValue: key)] = (current.perTool[key] ?? 0) - (previous.perTool[key] ?? 0)
        }
        let delta = current.perTool.values.reduce(0, +) - previous.perTool.values.reduce(0, +)
        return CareGrowth(since: previous.finishedAt, aiToolsDelta: delta, perTool: perTool)
    }
}
