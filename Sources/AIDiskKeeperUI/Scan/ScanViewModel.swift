import DiskKeeperCore
import Foundation
import Observation

@MainActor @Observable
public final class ScanViewModel {
    public enum Phase: Equatable { case idle, starting, scanning, cancelling, finished, cancelled, failed(String) }

    public private(set) var phase: Phase = .idle
    /// Last `.progress` event.
    public private(set) var progress: ScanProgress?
    /// Live during a scan (flushed on each progress event); equals `result.items` after a terminal event.
    public private(set) var items: [ScanItem] = []
    public private(set) var warnings: [ScanWarning] = []
    /// Set on `.finished` / `.cancelled`.
    public private(set) var result: ScanResult?
    /// +1 on every `startScan()`; T10 clears its selection when this changes.
    public private(set) var scanGeneration = 0
    public private(set) var lastScanFinishedAt: Date?

    public var isScanning: Bool { phase == .starting || phase == .scanning || phase == .cancelling }
    /// Stored and updated incrementally on flush; recomputed once at a terminal event.
    public private(set) var totals = ScanTotals()

    @ObservationIgnored private let makeEngine: @Sendable () throws -> any ScanEngineProtocol
    /// What stops the current stream: the engine's `cancel`, or whatever `consume(_:cancel:)` was given.
    @ObservationIgnored private var cancelAction: (@Sendable () async -> Void)?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    /// The off-main engine build of a starting scan: cancelled when the model goes away (a cancel while starting still lets the engine be built, then cancels it).
    @ObservationIgnored private var building: DetachedBuild<any ScanEngineProtocol>?
    @ObservationIgnored private var pending: [ScanItem] = []
    @ObservationIgnored private var sawTerminal = false
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var cancelRequestedEarly = false
    @ObservationIgnored private var itemIndex: [ScanItem.ID: Int] = [:]
    @ObservationIgnored private var lastFlush = ContinuousClock.Instant.now - .seconds(3600)
    /// Coalesces UI-visible updates: at most one flush per interval (terminal events always flush).
    @ObservationIgnored private let flushInterval: Duration = .milliseconds(200)

    public init(makeEngine: @escaping @Sendable () throws -> any ScanEngineProtocol) {
        self.makeEngine = makeEngine
    }

    public func item(id: ScanItem.ID) -> ScanItem? {
        guard let i = itemIndex[id], i < items.count, items[i].id == id else { return nil }
        return items[i]
    }

    /// No-op while a scan is running.
    public func startScan() {
        guard !isScanning else { return }
        prepare()
        // Rule loading reads JSON from disk: keep it off the main actor.
        let build = DetachedBuild(makeEngine)
        building = build
        let generation = scanGeneration
        consumer = Task { [weak self] in
            do {
                let engine = try await build.value()
                guard let self, self.scanGeneration == generation else { return }
                self.building = nil
                let stream = try await engine.scan()
                await self.run(stream, cancel: { await engine.cancel() })
            } catch is CancellationError {
                self?.startCancelled(generation: generation)
            } catch {
                self?.fail(error)
            }
        }
    }

    /// Shows the events of a scan that somebody else drives (the Care Scan feeds the rule stage's events here), exactly
    /// like `startScan()` does for its own engine. `cancel` is what a `cancelScan()` calls. No-op while a scan is running.
    public func consume(_ events: AsyncStream<ScanEvent>, cancel: @escaping @Sendable () async -> Void) {
        guard !isScanning else { return }
        prepare()
        consumer = Task { [weak self] in await self?.run(events, cancel: cancel) }
    }

    private func prepare() {
        phase = .starting
        scanGeneration += 1
        items = []
        warnings = []
        result = nil
        progress = nil
        pending = []
        totals = ScanTotals()
        itemIndex = [:]
        lastFlush = ContinuousClock.Instant.now - .seconds(3600)
        sawTerminal = false
        cancelRequestedEarly = false
        startedAt = Date()
    }

    private func run(_ stream: AsyncStream<ScanEvent>, cancel: @escaping @Sendable () async -> Void) async {
        cancelAction = cancel
        phase = cancelRequestedEarly ? .cancelling : .scanning
        if cancelRequestedEarly { Task { await cancel() } }
        // Keep consuming until the terminal event, even after cancel: dropping the stream would lose the partial result.
        for await event in stream { apply(event) }
        streamEnded()
    }

    /// No-op unless a scan is starting or running.
    public func cancelScan() {
        switch phase {
        case .starting:
            cancelRequestedEarly = true
            phase = .cancelling
        case .scanning:
            phase = .cancelling
            if let cancelAction { Task { await cancelAction() } }
        default:
            return
        }
    }

    /// T10: drop items that were moved to Trash, without a rescan.
    public func removeItems(_ ids: Set<ScanItem.ID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        pending.removeAll { ids.contains($0.id) }
        rebuildDerived()
        if let r = result {
            result = ScanResult(items: items, warnings: r.warnings, startedAt: r.startedAt,
                                finishedAt: r.finishedAt, wasCancelled: r.wasCancelled)
        }
    }

    // MARK: Events

    private func apply(_ event: ScanEvent) {
        switch event {
        case .started:
            break
        case .itemFound(let item):
            pending.append(item)
        case .progress(let p):
            // While stopping, just drain to the terminal event: it replaces everything anyway.
            guard phase != .cancelling else { break }
            let now = ContinuousClock.Instant.now
            guard now - lastFlush >= flushInterval else { break }
            lastFlush = now
            flushPending()
            progress = p
        case .warning(let w):
            warnings.append(w)
        case .finished(let r):
            terminal(r, cancelled: false)
        case .cancelled(let r):
            terminal(r, cancelled: true)
        }
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        for item in pending {
            itemIndex[item.id] = items.count
            items.append(item)
            totals.add(item)
        }
        pending = []
    }

    private func terminal(_ r: ScanResult, cancelled: Bool) {
        guard !sawTerminal else { return }
        sawTerminal = true
        pending = []
        items = r.items
        rebuildDerived()
        warnings = r.warnings
        result = r
        lastScanFinishedAt = r.finishedAt ?? Date()
        cancelAction = nil
        phase = cancelled ? .cancelled : .finished
    }

    private func rebuildDerived() {
        totals = ScanTotals(items: items)
        itemIndex = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func streamEnded() {
        if !sawTerminal {
            // Belt and braces: every scan ends in exactly one terminal phase.
            flushPending()
            terminal(ScanResult(items: items, warnings: warnings, startedAt: startedAt,
                                finishedAt: Date(), wasCancelled: true), cancelled: true)
        }
        consumer = nil
    }

    /// The engine build was cancelled before a scan started: end in the cancelled phase with nothing found.
    private func startCancelled(generation: Int) {
        guard scanGeneration == generation, !sawTerminal else { return }
        building = nil
        terminal(ScanResult(items: [], warnings: [], startedAt: startedAt, finishedAt: Date(), wasCancelled: true), cancelled: true)
        consumer = nil
    }

    private func fail(_ error: Error) {
        building = nil
        pending = []
        cancelAction = nil
        consumer = nil
        phase = .failed(String(describing: error))
    }
}
