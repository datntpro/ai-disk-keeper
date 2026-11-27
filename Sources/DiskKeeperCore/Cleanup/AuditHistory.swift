import Darwin
import Foundation

/// One readable line of `audit.jsonl`.
public enum AuditEntry: Sendable, Hashable {
    case cleanup(AuditRecord)
    case quit(AppQuitAuditRecord)
    /// A well-formed line from a newer schema this build can't interpret. Counted, never dropped silently.
    case unknown
}

/// Lines grouped by `runID` (cleanup) or `flowID` (app quit).
public struct AuditRun: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case cleanup, appQuit }
    public let id: UUID
    public let kind: Kind
    public let date: Date
    public let records: [AuditRecord]
    public let quits: [AppQuitAuditRecord]
    /// Items acted on: trashed, deleted or run by their tool.
    public let items: Int
    /// `trashed` + `deleted` bytes only.
    public let bytesReclaimed: Int64
    public let skipped: Int
    public let failed: Int
    public let action: CleanupAction?
}

public struct AuditHistory: Sendable {
    public var entries: [AuditEntry]
    /// Newest first.
    public var runs: [AuditRun]
    public var malformedLines: Int
    public var unknownLines: Int
    /// The log exceeded the read cap: only its tail was read.
    public var truncatedHead: Bool
    public var lifetimeReclaimed: Int64

    public static let empty = AuditHistory(entries: [], runs: [], malformedLines: 0, unknownLines: 0,
                                           truncatedHead: false, lifetimeReclaimed: 0)
}

/// Read-only. Never writes, rotates or repairs the log.
public enum AuditHistoryReader {
    public static let defaultMaxBytes = 50 * 1024 * 1024

    private struct Probe: Decodable { let schemaVersion: Int?; let kind: String? }

    /// A missing file is an empty history. Beyond `maxBytes` only the tail is read and the first partial line dropped.
    public static func read(_ url: URL, maxBytes: Int = defaultMaxBytes) throws -> AuditHistory {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return .empty }
            throw AuditLogError.posix("open \(url.path)", errno)
        }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw AuditLogError.posix("fstat", errno) }
        let size = Int(st.st_size)
        let truncated = size > maxBytes
        let start = truncated ? size - maxBytes : 0
        var data = Data(count: size - start)
        var got = 0
        try data.withUnsafeMutableBytes { raw in
            while got < raw.count {
                let n = pread(fd, raw.baseAddress! + got, raw.count - got, off_t(start + got))
                if n < 0 { if errno == EINTR { continue }; throw AuditLogError.posix("read", errno) }
                if n == 0 { break }
                got += n
            }
        }
        data = data.prefix(got)
        if truncated, let nl = data.firstIndex(of: 0x0A) { data = data.suffix(from: data.index(after: nl)) }
        return parse(data, truncatedHead: truncated)
    }

    public static func parse(_ data: Data, truncatedHead: Bool = false) -> AuditHistory {
        let decoder = DiskKeeperJSON.makeDecoder()
        var entries: [AuditEntry] = []
        var malformed = 0, unknown = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let bytes = Data(line)
            guard let probe = try? decoder.decode(Probe.self, from: bytes) else { malformed += 1; continue }
            if let v = probe.schemaVersion, v > 1 { entries.append(.unknown); unknown += 1; continue }
            if probe.kind == "appQuit" {
                if let q = try? decoder.decode(AppQuitAuditRecord.self, from: bytes) { entries.append(.quit(q)) } else { malformed += 1 }
            } else if probe.kind != nil {
                entries.append(.unknown); unknown += 1
            } else if let r = try? decoder.decode(AuditRecord.self, from: bytes) {
                entries.append(.cleanup(r))
            } else {
                malformed += 1
            }
        }
        let runs = group(settleIntents(entries))
        let lifetime = runs.reduce(Int64(0)) { $0 + $1.bytesReclaimed }
        return AuditHistory(entries: entries, runs: runs, malformedLines: malformed, unknownLines: unknown,
                            truncatedHead: truncatedHead, lifetimeReclaimed: lifetime)
    }

    /// An `intent` line is superseded by a later outcome line for the same item and command; one with no outcome
    /// (crash between intent and outcome) stays visible as its own entry and counts as nothing.
    static func settleIntents(_ entries: [AuditEntry]) -> [AuditEntry] {
        var settled = Set<String>()
        var out: [AuditEntry] = []
        for e in entries.reversed() {
            if case .cleanup(let r) = e {
                let key = r.itemID + "\u{0}" + (r.command ?? []).joined(separator: " ")
                if r.result == AuditRecord.intentResult {
                    if settled.contains(key) { continue }
                } else if r.command != nil { settled.insert(key) }
            }
            out.append(e)
        }
        return out.reversed()
    }

    static func group(_ entries: [AuditEntry]) -> [AuditRun] {
        var cleanup: [UUID: [AuditRecord]] = [:]
        var quits: [UUID: [AppQuitAuditRecord]] = [:]
        for e in entries {
            switch e {
            case .cleanup(let r): cleanup[r.runID, default: []].append(r)
            case .quit(let q): quits[q.flowID, default: []].append(q)
            case .unknown: break
            }
        }
        var runs: [AuditRun] = cleanup.map { id, recs in
            let reclaimed = recs.filter { $0.result == "trashed" || $0.result == "deleted" }.reduce(Int64(0)) { $0 + $1.bytes }
            let acted = recs.filter { ["trashed", "deleted", "ran"].contains($0.result) }.count
            return AuditRun(id: id, kind: .cleanup, date: recs.map(\.timestamp).min() ?? .distantPast, records: recs, quits: [],
                            items: acted, bytesReclaimed: reclaimed, skipped: recs.filter { $0.result == "skipped" }.count,
                            failed: recs.filter { $0.result == "failed" }.count, action: recs.first?.action)
        }
        runs += quits.map { id, qs in
            AuditRun(id: id, kind: .appQuit, date: qs.map(\.timestamp).min() ?? .distantPast, records: [], quits: qs,
                     items: 0, bytesReclaimed: 0, skipped: 0, failed: qs.filter { $0.result == "stillRunning" }.count, action: nil)
        }
        return runs.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id.uuidString < $1.id.uuidString }
    }
}

/// RFC 4180 export, one row per readable record, in file order.
public enum AuditCSV {
    public static let header = ["timestamp", "runID", "result", "action", "bytes", "path", "trashPath", "ruleID", "tool",
                                "reasons", "error", "bundleID", "command", "exitStatus"]

    public static func export(_ history: AuditHistory) -> String {
        var out = header.joined(separator: ",") + "\r\n"
        for entry in history.entries {
            let row: [String]
            switch entry {
            case .cleanup(let r):
                row = [stamp(r.timestamp), r.runID.uuidString, r.result, r.action.rawValue, String(r.bytes), r.path,
                       r.trashPath ?? "", r.ruleID, r.tool.rawValue, r.reasons.joined(separator: ";"), r.error ?? "",
                       r.bundleID ?? "", (r.command ?? []).joined(separator: " "), r.exitStatus.map(String.init) ?? ""]
            case .quit(let q):
                row = [stamp(q.timestamp), q.flowID.uuidString, q.result ?? q.phase, "quit:\(q.mode)", "0", q.appPath, "", "", "",
                       q.reasons.joined(separator: ";"), q.error ?? "", q.bundleID, "", ""]
            case .unknown: continue
            }
            out += row.map(field).joined(separator: ",") + "\r\n"
        }
        return out
    }

    static func stamp(_ d: Date) -> String { d.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }

    /// First scalars that make a spreadsheet read a cell as a formula (also after leading spaces):
    /// ASCII leaders, line breaks and tab, the full-width forms of = + - @, and a BOM.
    private static let formulaLeaders: Set<Unicode.Scalar> = [
        "=", "+", "-", "@", "\t", "\r", "\n", "\u{FF1D}", "\u{FF0B}", "\u{FF0D}", "\u{FF20}", "\u{FEFF}",
    ]

    /// One CSV cell: neutralises formula-leading text with a single quote, then RFC 4180 quoting.
    /// Works on unicode scalars: Swift treats CRLF as one Character, which would slip past both checks.
    /// Plain integers (bytes, exit status) are left alone so negative numbers stay numbers.
    static func field(_ raw: String) -> String {
        var s = raw
        let isInteger = Int(raw).map(String.init) == raw
        if !isInteger, let first = raw.unicodeScalars.drop(while: { $0 == " " }).first, formulaLeaders.contains(first) { s = "'" + raw }
        guard s.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
