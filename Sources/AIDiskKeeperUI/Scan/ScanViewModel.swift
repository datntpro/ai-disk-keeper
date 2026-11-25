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
    public var totals: ScanTotals { ScanTotals(items: items) }

    @ObservationIgnored private let makeEngine: @Sendable () throws -> any ScanEngineProtocol
    @ObservationIgnored private var engine: (any ScanEngineProtocol)?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var pending: [ScanItem] = []
    @ObservationIgnored private var sawTerminal = false
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var cancelRequestedEarly = false

    public init(makeEngine: @escaping @Sendable () throws -> any ScanEngineProtocol) {
        self.makeEngine = makeEngine
    }

    public func item(id: ScanItem.ID) -> ScanItem? { items.first { $0.id == id } }

    /// No-op while a scan is running.
    public func startScan() {
        guard !isScanning else { return }
        phase = .starting
        scanGeneration += 1
        items = []
        warnings = []
        result = nil
        progress = nil
        pending = []
        sawTerminal = false
        cancelRequestedEarly = false
        startedAt = Date()
        let make = makeEngine
        let generation = scanGeneration
        consumer = Task { [weak self] in
            do {
                // Rule loading reads JSON from disk: keep it off the main actor.
                let engine = try await Task.detached { try make() }.value
                guard let self, self.scanGeneration == generation else { return }
                self.engine = engine
                let stream = try await engine.scan()
                self.phase = self.cancelRequestedEarly ? .cancelling : .scanning
                if self.cancelRequestedEarly { Task { await engine.cancel() } }
                // Keep consuming until the terminal event, even after cancel: dropping the stream would lose the partial result.
                for await event in stream { self.apply(event) }
                self.streamEnded()
            } catch {
                self?.fail(error)
            }
        }
    }

    /// No-op unless a scan is starting or running.
    public func cancelScan() {
        switch phase {
        case .starting:
            cancelRequestedEarly = true
            phase = .cancelling
        case .scanning:
            phase = .cancelling
            if let engine { Task { await engine.cancel() } }
        default:
            return
        }
    }

    /// T10: drop items that were moved to Trash, without a rescan.
    public func removeItems(_ ids: Set<ScanItem.ID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        pending.removeAll { ids.contains($0.id) }
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
        items.append(contentsOf: pending)
        pending = []
    }

    private func terminal(_ r: ScanResult, cancelled: Bool) {
        guard !sawTerminal else { return }
        sawTerminal = true
        pending = []
        items = r.items
        warnings = r.warnings
        result = r
        lastScanFinishedAt = r.finishedAt ?? Date()
        engine = nil
        phase = cancelled ? .cancelled : .finished
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

    private func fail(_ error: Error) {
        pending = []
        engine = nil
        consumer = nil
        phase = .failed(String(describing: error))
    }
}
