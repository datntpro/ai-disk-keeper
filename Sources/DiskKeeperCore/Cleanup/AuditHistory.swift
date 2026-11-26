import Darwin
import Foundation

/// One line of `audit.jsonl`, as the History screen sees it.
public enum AuditEntry: Sendable, Hashable {
    case cleanup(AuditRecord)
    case appQuit(AppQuitAuditRecord)
    /// A well-formed JSON line this build can't interpret (for example `schemaVersion > 1`). Counted, never dropped silently.
    case unknown(schemaVersion: Int)
}

/// All lines that share a `runID` (cleanup) or `flowID` (Uninstaller quit flow).
public struct AuditRun: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case cleanup, quit }
    public let id: UUID
    public let kind: Kind
    /// Earliest timestamp of the run.
    public let date: Date
    public let records: [AuditRecord]
    public let quitEvents: [AppQuitAuditRecord]

    /// Bytes of `trashed` + `deleted` entries. Quit flows never count.
    public var reclaimedBytes: Int64 { records.filter(AuditHistory.isReclaiming).reduce(0) { $0 + $1.bytes } }
    public var reclaimedCount: Int { records.filter(AuditHistory.isReclaiming).count }
    public var skippedCount: Int { records.filter { $0.result == "skipped" }.count }
    public var failedCount: Int { records.filter { $0.result == "failed" }.count }
    public var itemCount: Int { kind == .quit ? quitEvents.count : records.count }
}

public struct AuditHistory: Sendable, Hashable {
    /// Every understood line, in file order.
    public var entries: [AuditEntry]
    /// Newest first.
    public var runs: [AuditRun]
    /// Lines that were not valid JSON or didn't match any known shape (including a truncated last line).
    public var malformedLines: Int
    public var unknownEntries: Int
    /// The file was bigger than the read cap: only its tail was read.
    public var truncatedHead: Bool
    /// Sum of `trashed` + `deleted` bytes over everything that was read (never limited by a filter).
    public var lifetimeReclaimed: Int64

    public static let empty = AuditHistory(entries: [], runs: [], malformedLines: 0, unknownEntries: 0,
                                           truncatedHead: false, lifetimeReclaimed: 0)

    public var isEmpty: Bool { entries.isEmpty && malformedLines == 0 && unknownEntries == 0 }

    static func isReclaiming(_ r: AuditRecord) -> Bool { r.result == "trashed" || r.result == "deleted" }
}

/// Read-only parser for `audit.jsonl`. Never writes, rotates or repairs the file.
public enum AuditHistoryReader {
    public static let defaultReadCap = 50 * 1024 * 1024

    /// A missing file is an empty history. Other I/O errors throw.
    public static func read(_ url: URL, maxBytes: Int = defaultReadCap) throws -> AuditHistory {
        var truncated = false
        var data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = Int(try handle.seekToEnd())
            if size > maxBytes {
                try handle.seek(toOffset: UInt64(size - maxBytes))
                data = try handle.readToEnd() ?? Data()
                truncated = true
                // Drop the (probably partial) first line.
                if let nl = data.firstIndex(of: 0x0A) { data = Data(data[data.index(after: nl)...]) } else { data = Data() }
            } else {
                try handle.seek(toOffset: 0)
                data = try handle.readToEnd() ?? Data()
            }
        } catch {
            var st = stat()
            if lstat(url.path, &st) != 0, errno == ENOENT { return .empty }
            throw error
        }
        return parse(data, truncatedHead: truncated)
    }

    public static func parse(_ data: Data, truncatedHead: Bool = false) -> AuditHistory {
        let decoder = DiskKeeperJSON.makeDecoder()
        var entries: [AuditEntry] = []
        var malformed = 0
        var unknown = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let bytes = Data(line)
            guard let probe = try? decoder.decode(Probe.self, from: bytes) else { malformed += 1; continue }
            if let v = probe.schemaVersion, v > 1 {
                entries.append(.unknown(schemaVersion: v)); unknown += 1; continue
            }
            if probe.kind == "appQuit" {
                if let q = try? decoder.decode(AppQuitAuditRecord.self, from: bytes) { entries.append(.appQuit(q)) } else { malformed += 1 }
            } else if probe.kind == nil, let r = try? decoder.decode(AuditRecord.self, from: bytes) {
                entries.append(.cleanup(r))
            } else {
                malformed += 1
            }
        }
        return AuditHistory(entries: entries, runs: group(entries), malformedLines: malformed, unknownEntries: unknown,
                            truncatedHead: truncatedHead, lifetimeReclaimed: lifetime(entries))
    }

    private struct Probe: Decodable { let schemaVersion: Int?; let kind: String? }

    private static func lifetime(_ entries: [AuditEntry]) -> Int64 {
        entries.reduce(0) {
            if case .cleanup(let r) = $1, AuditHistory.isReclaiming(r) { return $0 + r.bytes }
            return $0
        }
    }

    private static func group(_ entries: [AuditEntry]) -> [AuditRun] {
        var cleanups: [UUID: [AuditRecord]] = [:]
        var quits: [UUID: [AppQuitAuditRecord]] = [:]
        for entry in entries {
            switch entry {
            case .cleanup(let r): cleanups[r.runID, default: []].append(r)
            case .appQuit(let q): quits[q.flowID, default: []].append(q)
            case .unknown: break
            }
        }
        var runs = cleanups.map { id, records in
            AuditRun(id: id, kind: .cleanup, date: records.map(\.timestamp).min() ?? .distantPast, records: records, quitEvents: [])
        }
        runs += quits.map { id, events in
            AuditRun(id: id, kind: .quit, date: events.map(\.timestamp).min() ?? .distantPast, records: [], quitEvents: events)
        }
        return runs.sorted { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) }
    }
}

/// RFC 4180 export of the audit log. One row per understood line, in file order.
public enum AuditCSV {
    public static let header = ["timestamp", "runID", "result", "action", "bytes", "path", "trashPath", "ruleID", "tool",
                                "reasons", "error", "bundleID", "command", "exitStatus"]

    public static func export(_ history: AuditHistory) -> String {
        var rows: [[String]] = [header]
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        for entry in history.entries {
            switch entry {
            case .cleanup(let r):
                rows.append([r.timestamp.formatted(iso), r.runID.uuidString, r.result, r.action.rawValue, String(r.bytes), r.path,
                             r.trashPath ?? "", r.ruleID, r.tool.rawValue, r.reasons.joined(separator: ";"), r.error ?? "",
                             r.bundleID ?? "", r.command?.joined(separator: " ") ?? "", r.exitStatus.map { String($0) } ?? ""])
            case .appQuit(let q):
                rows.append([q.timestamp.formatted(iso), q.flowID.uuidString, q.result ?? q.phase, "quit.\(q.mode)", "0", q.appPath,
                             "", "", "", q.reasons.joined(separator: ";"), q.error ?? "", q.bundleID, "", ""])
            case .unknown: continue
            }
        }
        return rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func field(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Whether "Reveal in Trash" may be offered for a recorded `trashPath`.
public enum TrashRevealPolicy {
    /// Lexical check: the path has no `..` and lies under `~/.Trash` or `<volume>/.Trashes/<uid>`.
    public static func isInsideTrash(_ path: String, home: String, uid: uid_t = getuid()) -> Bool {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.hasPrefix("/"), !comps.contains(".."), !comps.contains(".") else { return false }
        let homeComps = home.split(separator: "/").map(String.init)
        let own = homeComps + [".Trash"]
        if comps.count > own.count, Array(comps.prefix(own.count)) == own { return true }
        let u = String(uid)
        if comps.count > 2, comps[0] == ".Trashes", comps[1] == u { return true }
        if comps.count > 4, comps[0] == "Volumes", comps[2] == ".Trashes", comps[3] == u { return true }
        return false
    }

    /// `lstat` without following the final component.
    public static func existsNow(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}
