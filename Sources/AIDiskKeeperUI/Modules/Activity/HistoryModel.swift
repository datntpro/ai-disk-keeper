import DiskKeeperCore
import Foundation
import Observation

/// State of the Cleanup History screen. Read-only over `audit.jsonl`: it never writes, rotates or repairs it.
@MainActor @Observable
final class HistoryModel {
    enum Phase: Equatable { case idle, loading, ready, failed }

    typealias Reading = @Sendable (URL) async throws -> AuditHistory

    private(set) var phase: Phase = .idle
    private(set) var history: AuditHistory = .empty
    var selectedRunID: UUID?
    var finder: any FinderRevealing = SystemFinder()

    let logURL: URL
    let home: String
    @ObservationIgnored private let reader: Reading
    @ObservationIgnored private let trashProbe: @Sendable (String) -> Bool
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(logURL: URL, home: String,
         reader: @escaping Reading = { url in try await Task.detached { try AuditHistoryReader.read(url) }.value },
         trashProbe: @escaping @Sendable (String) -> Bool = TrashRevealPolicy.existsNow) {
        self.logURL = logURL
        self.home = home
        self.reader = reader
        self.trashProbe = trashProbe
    }

    var runs: [AuditRun] { history.runs }
    var selectedRun: AuditRun? { runs.first { $0.id == selectedRunID } }
    var lifetimeReclaimed: Int64 { history.lifetimeReclaimed }
    var unreadableCount: Int { history.malformedLines + history.unknownEntries }

    /// Loads off the main actor. A later call replaces an earlier one still in flight.
    func load() {
        loadTask?.cancel()
        if phase != .ready { phase = .loading }
        let url = logURL
        loadTask = Task { [reader] in
            do {
                let result = try await reader(url)
                guard !Task.isCancelled else { return }
                history = result
                if let sel = selectedRunID, !result.runs.contains(where: { $0.id == sel }) { selectedRunID = nil }
                phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed
            }
        }
    }

    /// For tests: wait for the in-flight load.
    func settle() async { await loadTask?.value }

    /// Reveal is offered only if the recorded Trash path is inside the user's Trash and still there (lstat, no follow).
    func canRevealInTrash(_ record: AuditRecord) -> Bool {
        guard let path = record.trashPath, record.result == "trashed" else { return false }
        return TrashRevealPolicy.isInsideTrash(path, home: home) && trashProbe(path)
    }

    func revealInTrash(_ record: AuditRecord) {
        guard canRevealInTrash(record), let path = record.trashPath else { return }
        finder.reveal(URL(fileURLWithPath: path))
    }

    func revealLog() { finder.reveal(logURL) }

    func csv() -> String { AuditCSV.export(history) }
}
