import Foundation
import Testing
@testable import DiskKeeperCore

private func rec(_ run: UUID, _ result: String, bytes: Int64 = 100, path: String = "/a", at t: Double = 1_700_000_000,
                 reasons: [String] = [], error: String? = nil, action: CleanupAction = .trash) -> AuditRecord {
    AuditRecord(timestamp: Date(timeIntervalSince1970: t), runID: run, itemID: "i", path: path, bytes: bytes, action: action,
                result: result, trashPath: result == "trashed" ? "/Users/x/.Trash/a" : nil, ruleID: "r.1", tool: "npm",
                reasons: reasons, error: error)
}

private func line(_ r: some Encodable) throws -> String {
    String(decoding: try DiskKeeperJSON.makeEncoder().encode(r), as: UTF8.self)
}

private func tempFile(_ s: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adk-hist-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let u = dir.appendingPathComponent("audit.jsonl")
    try Data(s.utf8).write(to: u)
    return u
}

@Suite struct AuditHistoryReaderTests {
    @Test func validLinesGroupByRun() throws {
        let a = UUID(), b = UUID()
        let text = try [rec(a, "trashed", bytes: 10), rec(a, "skipped", reasons: ["keepTier"]), rec(a, "failed", error: "boom"),
                        rec(b, "deleted", bytes: 5, at: 1_700_000_100, action: .deletePermanently)].map(line).joined(separator: "\n") + "\n"
        let h = try AuditHistoryReader.read(tempFile(text))
        #expect(h.runs.count == 2)
        #expect(h.runs[0].id == b)
        let ra = h.runs[1]
        #expect(ra.items == 1 && ra.skipped == 1 && ra.failed == 1 && ra.bytesReclaimed == 10)
        #expect(h.lifetimeReclaimed == 15)
        #expect(h.malformedLines == 0)
    }

    @Test func corruptedMiddleLineCounted() throws {
        let a = UUID()
        let text = try line(rec(a, "trashed")) + "\n{not json\n" + line(rec(a, "trashed")) + "\n"
        let h = try AuditHistoryReader.read(tempFile(text))
        #expect(h.malformedLines == 1)
        #expect(h.runs.first?.items == 2)
    }

    @Test func truncatedLastLineWithoutNewline() throws {
        let a = UUID()
        let full = try line(rec(a, "trashed"))
        let h = try AuditHistoryReader.read(tempFile(full + "\n" + String(full.prefix(40))))
        #expect(h.malformedLines == 1)
        #expect(h.entries.count == 1)
    }

    @Test func emptyAndMissing() throws {
        #expect(try AuditHistoryReader.read(tempFile("")).runs.isEmpty)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID()).jsonl")
        let h = try AuditHistoryReader.read(missing)
        #expect(h.runs.isEmpty && h.malformedLines == 0)
    }

    @Test func quitLinesGroupedAndExcludedFromBytes() throws {
        let flow = UUID()
        let q1 = AppQuitAuditRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_000), flowID: flow, bundleID: "com.x", appPath: "/Applications/X.app",
                                    mode: "graceful", phase: "requested", result: nil, pids: [1], instanceCount: 1)
        let q2 = AppQuitAuditRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_001), flowID: flow, bundleID: "com.x", appPath: "/Applications/X.app",
                                    mode: "graceful", phase: "result", result: "quit", pids: [1], instanceCount: 1)
        let text = try [line(q1), line(q2)].joined(separator: "\n") + "\n"
        let h = try AuditHistoryReader.read(tempFile(text))
        #expect(h.runs.count == 1 && h.runs[0].kind == .appQuit && h.runs[0].quits.count == 2)
        #expect(h.lifetimeReclaimed == 0 && h.malformedLines == 0)
    }

    @Test func futureSchemaCountedAsUnknown() throws {
        let a = UUID()
        let future = try line(rec(a, "trashed")).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        let h = try AuditHistoryReader.read(tempFile(future + "\n"))
        #expect(h.unknownLines == 1 && h.malformedLines == 0 && h.runs.isEmpty)
    }

    @Test func bigFileReadsTailAndDropsPartialLine() throws {
        let a = UUID()
        let one = try line(rec(a, "trashed", bytes: 1)) + "\n"
        let text = String(repeating: one, count: 20)
        let u = try tempFile(text)
        let cap = one.utf8.count * 5 + 10
        let h = try AuditHistoryReader.read(u, maxBytes: cap)
        #expect(h.truncatedHead)
        #expect(h.entries.count == 5)
        #expect(h.malformedLines == 0)
        #expect(try Data(contentsOf: u) == Data(text.utf8))
    }
}

@Suite struct AuditCSVTests {
    /// Minimal RFC 4180 parser for the round trip.
    static func parse(_ s: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cur = "", quoted = false
        let chars = Array(s.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" { if i + 1 < chars.count, chars[i + 1] == "\"" { cur.unicodeScalars.append(c); i += 1 } else { quoted = false } }
                else { cur.unicodeScalars.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(cur); cur = "" }
            else if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { row.append(cur); cur = ""; rows.append(row); row = []; i += 1 }
            else { cur.unicodeScalars.append(c) }
            i += 1
        }
        return rows
    }

    @Test func roundTripEveryField() throws {
        let run = UUID()
        let r1 = AuditRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_000.25), runID: run, itemID: "i", path: "/a,b/\"q\"\nnew",
                             bytes: 42, action: .trash, result: "trashed", trashPath: "/Users/x/.Trash/a", ruleID: "r.1", tool: "npm",
                             reasons: ["x", "y"], error: "has, comma", bundleID: "com.a.b", command: ["/usr/bin/npm", "cache", "clean"], exitStatus: 0)
        let r2 = rec(run, "skipped", path: "/plain", reasons: ["keepTier"])
        let h = AuditHistoryReader.parse(Data(([try line(r1), try line(r2)].joined(separator: "\n") + "\n").utf8))
        let rows = Self.parse(AuditCSV.export(h))
        #expect(rows.count == 3)
        #expect(rows[0] == AuditCSV.header)
        let f = rows[1]
        #expect(f[1] == run.uuidString && f[2] == "trashed" && f[3] == "trash" && f[4] == "42")
        #expect(f[5] == r1.path && f[6] == "/Users/x/.Trash/a" && f[7] == "r.1" && f[8] == "npm")
        #expect(f[9] == "x;y" && f[10] == "has, comma" && f[11] == "com.a.b" && f[12] == "/usr/bin/npm cache clean" && f[13] == "0")
        #expect(try Date(f[0], strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)).timeIntervalSince1970 == 1_700_000_000.25)
        #expect(rows[2][5] == "/plain" && rows[2][9] == "keepTier" && rows[2][13] == "")
    }

    @Test func fieldNeutralisesFormulaLeadersInEveryColumn() {
        for lead in ["=", "+", "-", "@", "\t", "\r", "\n"] {
            let hostile = lead + "HYPERLINK(\"http://x\")"
            let out = AuditCSV.field(hostile)
            let inner = out.hasPrefix("\"") ? String(out.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"") : out
            #expect(inner == "'" + hostile, "leader \(lead.debugDescription)")
            #expect(AuditCSV.field("  " + hostile).contains("'  " + lead))
        }
        #expect(AuditCSV.field("-1") == "-1")          // numbers stay numbers
        #expect(AuditCSV.field("/-etc/=x") == "/-etc/=x") // paths start with "/"
        #expect(AuditCSV.field("say \"hi\"\nnow") == "\"say \"\"hi\"\"\nnow\"")
    }

    @Test func hostileBundleIDErrorAndPathsAreNeutralisedInExport() throws {
        let run = UUID()
        let r = AuditRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_000), runID: run, itemID: "i", path: "/Apps/=cmd|' /C calc'!A1.app",
                            bytes: 1, action: .trash, result: "failed", trashPath: nil, ruleID: "r", tool: "npm", reasons: [],
                            error: "+SUM(1)", bundleID: "=HYPERLINK(\"http://evil\",\"x\")", command: ["@evil"], exitStatus: -1)
        let rows = Self.parse(AuditCSV.export(AuditHistoryReader.parse(Data((try line(r) + "\n").utf8))))
        let f = rows[1]
        #expect(f[5] == r.path)                    // absolute path, safe as is
        #expect(f[10] == "'+SUM(1)")
        #expect(f[11] == "'=HYPERLINK(\"http://evil\",\"x\")")
        #expect(f[12] == "'@evil")
        #expect(f[13] == "-1")
    }
}
