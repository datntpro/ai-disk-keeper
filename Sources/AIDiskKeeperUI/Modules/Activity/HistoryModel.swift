import DiskKeeperCore
import Foundation
import Observation

/// State of the Cleanup History screen. Read-only over `audit.jsonl`: this model never writes the log.
@MainActor @Observable
final class HistoryModel {
    enum Phase: Equatable { case idle, loading, ready, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var history: AuditHistory = .empty
    var selectedRunID: UUID?
    var finder: any FinderRevealing = SystemFinder()

    let logURL: URL
    private let uid: uid_t
    private let trashRoots: [String]
    @ObservationIgnored private let exists: (String) -> Bool
    @ObservationIgnored private let load: @Sendable (URL) throws -> AuditHistory

    init(logURL: URL, home: String, uid: uid_t = getuid(),
         exists: @escaping (String) -> Bool = HistoryModel.lstatExists,
         load: @escaping @Sendable (URL) throws -> AuditHistory = { try AuditHistoryReader.read($0) }) {
        self.logURL = logURL
        self.uid = uid
        self.trashRoots = [home + "/.Trash", "/.Trashes/\(uid)"]
        self.exists = exists
        self.load = load
    }

    var lifetimeReclaimed: Int64 { history.lifetimeReclaimed }
    var runs: [AuditRun] { history.runs }
    var selectedRun: AuditRun? { runs.first { $0.id == selectedRunID } }

    func refresh() async {
        if phase != .ready { phase = .loading }
        let url = logURL, load = load
        do {
            let h = try await Task.detached(priority: .utility) { try load(url) }.value
            history = h
            if let id = selectedRunID, !h.runs.contains(where: { $0.id == id }) { selectedRunID = nil }
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Enabled only when the item sits in a Trash and exists right now (lstat, never following a symlink).
    func canRevealInTrash(_ record: AuditRecord) -> Bool {
        guard let p = record.trashPath, isInsideTrash(p) else { return false }
        return exists(p)
    }

    func isInsideTrash(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
        if trashRoots.contains(where: { path.hasPrefix($0 + "/") }) { return true }
        // Other volumes: /Volumes/<name>/.Trashes/<uid>/…
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return parts.count > 4 && parts[0] == "Volumes" && parts[2] == ".Trashes" && parts[3] == String(uid)
    }

    func revealInTrash(_ record: AuditRecord) {
        guard canRevealInTrash(record), let p = record.trashPath else { return }
        finder.reveal(URL(fileURLWithPath: p))
    }

    func revealLog() { finder.reveal(logURL) }

    func csv() -> String { AuditCSV.export(history) }
    /// UTF-8 with a BOM, so Excel reads non-ASCII paths correctly (Numbers ignores it).
    func csvData() -> Data { Data(("\u{FEFF}" + csv()).utf8) }

    nonisolated static func lstatExists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}
