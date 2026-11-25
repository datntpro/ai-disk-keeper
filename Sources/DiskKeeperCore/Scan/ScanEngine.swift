import Foundation

public enum ScanEngineError: Error, Equatable { case alreadyRunning }

/// Runs scanners concurrently and turns what they report into one ordered, cancellable event stream.
///
/// The engine only ever drops items: it re-checks every item with the guard and rejects overlaps (the first
/// item to arrive wins). It never changes a tier. Callers should create a new engine per scan from the UI
/// (cheap); a second scan through the same engine reuses the same context, including `now`.
public actor ScanEngine {
    private let context: ScanContext
    private let scanners: [any Scanner]
    private let initialWarnings: [ScanWarning]
    private let progressInterval: Duration

    private var runTask: Task<Void, Never>?
    private var continuation: AsyncStream<ScanEvent>.Continuation?
    private var generation = 0
    private var items: [ScanItem] = []
    private var warnings: [ScanWarning] = []
    private var claims = PathClaimSet()
    private var perScanner: [String: ScannerProgress] = [:]
    private var finishedScanners = 0
    private var bytesFound: Int64 = 0
    private var terminated = false
    private var cancelRequested = false
    private var lastProgressAt: ContinuousClock.Instant?
    private var startedAt = Date()
    private var dirty = false                       // state changed since the last progress event
    private var claimOwner: [String: String] = [:]  // claimed physical path → rule id
    private var warnedOverlaps = Set<String>()
    private let physicalPaths = PhysicalPathResolver()

    public init(context: ScanContext, scanners: [any Scanner], initialWarnings: [ScanWarning] = [],
                progressInterval: Duration = .milliseconds(100)) {
        self.context = context
        self.scanners = scanners
        self.initialWarnings = initialWarnings
        self.progressInterval = progressInterval
    }

    /// Loads rules (bundled + user) with `ScanGuard.loaderFactory`, builds the `ScanGuard` from the rules'
    /// protect patterns, converts every `RuleLoadError` to a `.ruleError` warning, and puts `RuleScanner` first,
    /// then `extraScanners`. Throws if the guard cannot be built: it never scans without one.
    public static func makeDefault(environment: PathEnvironment = .current(),
                                   bundledRulesDirectory: URL? = CoreResources.rulesDirectoryURL,
                                   userRulesDirectory: URL? = nil,
                                   extraScanners: [any Scanner] = [],
                                   maxConcurrentSizing: Int = ProcessInfo.processInfo.activeProcessorCount,
                                   now: Date = Date()) throws -> ScanEngine {
        let loaded = RuleLoader(
            environment: environment, bundledRulesDirectory: bundledRulesDirectory,
            userRulesDirectory: userRulesDirectory,
            guardFactory: ScanGuard.loaderFactory(environment: environment)).load()
        let pathGuard = try ScanGuard(environment: environment, protectPatterns: loaded.protectPatterns)
        let context = ScanContext(environment: environment, pathGuard: pathGuard, now: now,
                                  maxConcurrentSizing: maxConcurrentSizing)
        let warnings = (loaded.errors + loaded.warnings).map {
            ScanWarning(kind: .ruleError, path: $0.file?.path, message: $0.description)
        }
        return ScanEngine(context: context, scanners: [RuleScanner(loadResult: loaded)] + extraScanners,
                          initialWarnings: warnings)
    }

    public var isRunning: Bool { runTask != nil }

    /// Starts a scan. Throws `.alreadyRunning` if one is in progress. The stream is unbounded; terminating it
    /// (the consumer cancels its `for await` task or drops the stream) cancels the scan.
    ///
    /// Single consumer: iterate the returned stream from one task only (concurrent iterators split the events
    /// and only one of them would see the terminal event); to fan out, re-broadcast from that task.
    public func scan() throws -> AsyncStream<ScanEvent> {
        guard runTask == nil else { throw ScanEngineError.alreadyRunning }
        let (stream, continuation) = AsyncStream.makeStream(of: ScanEvent.self, bufferingPolicy: .unbounded)
        generation += 1
        let gen = generation
        continuation.onTermination = { @Sendable [self] _ in
            Task { await self.cancel(generation: gen) }
        }
        self.continuation = continuation
        items = []
        warnings = []
        claims = PathClaimSet()
        claimOwner = [:]
        warnedOverlaps = []
        dirty = false
        perScanner = [:]
        finishedScanners = 0
        bytesFound = 0
        terminated = false
        cancelRequested = false
        startedAt = Date()
        lastProgressAt = ContinuousClock.now   // the first progress is throttled too
        runTask = Task { await self.run(generation: gen) }
        return stream
    }

    /// Idempotent. Safe to call when idle.
    public func cancel() {
        cancel(generation: generation)
    }

    private func cancel(generation gen: Int) {
        guard gen == generation, runTask != nil, !terminated else { return }
        cancelRequested = true
        runTask?.cancel()
    }

    // MARK: Run

    private func run(generation gen: Int) async {
        let id = UUID()
        continuation?.yield(.started(id: id, startedAt: startedAt, scannerIDs: scanners.map(\.id)))
        for w in initialWarnings { accept(w, generation: gen) }

        let context = self.context
        // Heartbeat: progress also advances on item arrivals and finished scanners, never only on scanner calls.
        let period = min(progressInterval, .milliseconds(250))
        let ticker = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: period)
                self.heartbeat(generation: gen)
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for scanner in scanners {
                let sink = ScanSink(
                    item: { [self] item in
                        // The guard check and path resolution run on the caller's task, not on the actor.
                        guard context.pathGuard.check(item.path).isAllowed else { return }
                        let physical = await self.physicalPaths.physical(item.path)
                        await self.accept(item, physical: physical, generation: gen)
                    },
                    warning: { [self] w in await self.accept(w, generation: gen) },
                    progress: { [self] p in await self.update(p, scanner: scanner.id, generation: gen) })
                group.addTask { [self] in
                    do {
                        try await scanner.scan(context: context, sink: sink)
                    } catch is CancellationError where Task.isCancelled {
                    } catch {
                        await self.accept(ScanWarning(kind: .scannerFailed, message: "\(scanner.id): \(error)"),
                                          generation: gen)
                    }
                    await self.scannerFinished(generation: gen)
                }
            }
        }
        ticker.cancel()
        finish(generation: gen)
    }

    private func heartbeat(generation gen: Int) {
        guard isOpen(gen), dirty else { return }
        emitProgressIfDue()
    }

    private func scannerFinished(generation gen: Int) {
        guard gen == generation, !terminated else { return }
        finishedScanners += 1
        dirty = true
        emitProgressIfDue()
    }

    private func isOpen(_ gen: Int) -> Bool { gen == generation && !terminated && !cancelRequested }

    private func accept(_ item: ScanItem, physical: String, generation gen: Int) {
        guard isOpen(gen) else { return }
        if let conflict = claims.claim(physical) {
            let claimed: String
            switch conflict { case .equal(let p), .inside(let p), .contains(let p): claimed = p }
            let earlier = claimOwner[claimed] ?? "?"
            // One warning per (rule, earlier rule) pair, not per item.
            if warnedOverlaps.insert(item.ruleID + "\u{0}" + earlier).inserted {
                accept(ScanWarning(kind: .ruleError, path: item.path, ruleID: item.ruleID,
                                   message: "\(item.ruleID): \(item.path) overlaps another item (\(earlier)); skipped"),
                       generation: gen)
            }
            return
        }
        claimOwner[physical] = item.ruleID
        items.append(item)
        bytesFound += item.sizeAllocated
        dirty = true
        continuation?.yield(.itemFound(item))
        emitProgressIfDue()
    }

    private func accept(_ warning: ScanWarning, generation gen: Int) {
        guard isOpen(gen) else { return }
        warnings.append(warning)
        continuation?.yield(.warning(warning))
    }

    private func update(_ progress: ScannerProgress, scanner: String, generation gen: Int) {
        guard isOpen(gen) else { return }
        perScanner[scanner] = progress
        dirty = true
        emitProgressIfDue()
    }

    /// Throttled; a throttled update stays `dirty` and the heartbeat emits it later (trailing edge).
    private func emitProgressIfDue() {
        let now = ContinuousClock.now
        if let last = lastProgressAt, now - last < progressInterval { return }
        lastProgressAt = now
        dirty = false
        continuation?.yield(.progress(snapshot()))
    }

    private func snapshot() -> ScanProgress {
        ScanProgress(scannersFinished: finishedScanners, scannersTotal: scanners.count,
                     candidatesFound: perScanner.values.reduce(0) { $0 + $1.candidatesFound },
                     candidatesSized: perScanner.values.reduce(0) { $0 + $1.candidatesSized },
                     itemsFound: items.count, bytesFound: bytesFound)
    }

    private func finish(generation gen: Int) {
        guard gen == generation, !terminated else { return }
        let wasCancelled = cancelRequested || Task.isCancelled
        continuation?.yield(.progress(snapshot()))
        let result = ScanResult(items: items, warnings: warnings, startedAt: startedAt,
                                finishedAt: Date(), wasCancelled: wasCancelled)
        terminated = true
        continuation?.yield(wasCancelled ? .cancelled(result) : .finished(result))
        continuation?.finish()
        continuation = nil
        runTask = nil
        // Free the per-scan state; the result already holds what callers need.
        items = []; warnings = []; claims = PathClaimSet(); claimOwner = [:]; warnedOverlaps = []
    }
}
