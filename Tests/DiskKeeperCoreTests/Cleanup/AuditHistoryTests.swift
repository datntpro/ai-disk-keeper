import XCTest
@testable import DiskKeeperCore

final class AuditHistoryTests: XCTestCase {
    private var dir: URL!
    private let run1 = UUID(), run2 = UUID(), flow = UUID()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func rec(_ run: UUID, _ result: String, bytes: Int64 = 100, path: String = "/a/b", t: TimeInterval = 1_700_000_000,
                     trash: String? = nil, reasons: [String] = [], error: String? = nil, command: [String]? = nil,
                     exit: Int32? = nil) -> AuditRecord {
        AuditRecord(timestamp: Date(timeIntervalSince1970: t), runID: run, itemID: "r|\(path)", path: path, bytes: bytes,
                    action: .trash, result: result, trashPath: trash, ruleID: "rule.x", tool: "claude", reasons: reasons,
                    error: error, bundleID: nil, command: command, exitStatus: exit)
    }
    private func line(_ r: some Encodable) throws -> String {
        String(decoding: try DiskKeeperJSON.makeEncoder().encode(r), as: UTF8.self)
    }
    private func quit(_ phase: String) -> AppQuitAuditRecord {
        AppQuitAuditRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_500), flowID: flow, bundleID: "com.x", appPath: "/Applications/X.app",
                           mode: "graceful", phase: phase, result: phase == "result" ? "quit" : nil, pids: [4], instanceCount: 1)
    }
    private func write(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("audit.jsonl")
        try Data(text.utf8).write(to: url)
        return url
    }

    func testValidLinesGroupIntoRunsAndLifetime() throws {
        let text = try [rec(run1, "trashed", bytes: 100), rec(run1, "skipped", bytes: 50, reasons: ["keepTier"]),
                        rec(run1, "failed", bytes: 7, error: "x"), rec(run2, "deleted", bytes: 1000, t: 1_700_001_000)]
            .map { try line($0) }.joined(separator: "\n") + "\n"
        let h = try AuditHistoryReader.read(write(text))
        XCTAssertEqual(h.entries.count, 4)
        XCTAssertEqual(h.runs.map(\.id), [run2, run1])  // newest first
        let r1 = h.runs[1]
        XCTAssertEqual(r1.reclaimedBytes, 100)
        XCTAssertEqual(r1.skippedCount, 1)
        XCTAssertEqual(r1.failedCount, 1)
        XCTAssertEqual(h.lifetimeReclaimed, 1100)
        XCTAssertEqual(h.malformedLines, 0)
    }

    func testCorruptMiddleLineAndTruncatedLastLine() throws {
        let good = try line(rec(run1, "trashed"))
        let truncated = String(try line(rec(run1, "trashed")).dropLast(20))
        let h = try AuditHistoryReader.read(write("\(good)\nnot json\n\(good)\n\(truncated)"))
        XCTAssertEqual(h.entries.count, 2)
        XCTAssertEqual(h.malformedLines, 2)
    }

    func testLastLineWithoutNewlineStillCountsWhenComplete() throws {
        let h = try AuditHistoryReader.read(write(try line(rec(run1, "trashed"))))
        XCTAssertEqual(h.entries.count, 1)
    }

    func testEmptyAndMissingFile() throws {
        XCTAssertTrue(try AuditHistoryReader.read(write("")).isEmpty)
        XCTAssertTrue(try AuditHistoryReader.read(dir.appendingPathComponent("nope.jsonl")).isEmpty)
    }

    func testAppQuitGroupedAndExcludedFromBytes() throws {
        let text = try [rec(run1, "trashed", bytes: 10)].map { try line($0) }.joined(separator: "\n") + "\n"
            + (try line(quit("requested"))) + "\n" + (try line(quit("result"))) + "\n"
        let h = try AuditHistoryReader.read(write(text))
        XCTAssertEqual(h.runs.count, 2)
        let q = try XCTUnwrap(h.runs.first { $0.kind == .quit })
        XCTAssertEqual(q.quitEvents.count, 2)
        XCTAssertEqual(q.reclaimedBytes, 0)
        XCTAssertEqual(h.lifetimeReclaimed, 10)
    }

    func testFutureSchemaVersionIsCountedAsUnknown() throws {
        let future = #"{"schemaVersion":2,"whatever":true}"#
        let h = try AuditHistoryReader.read(write("\(future)\n\(try line(rec(run1, "trashed")))\n"))
        XCTAssertEqual(h.unknownEntries, 1)
        XCTAssertEqual(h.entries.count, 2)
        XCTAssertEqual(h.malformedLines, 0)
        XCTAssertEqual(h.lifetimeReclaimed, 100)
    }

    func testHeadTruncationReadsTailAndDropsPartialLine() throws {
        let one = try line(rec(run1, "trashed", bytes: 1)) + "\n"
        let text = String(repeating: one, count: 10)
        let url = try write(text)
        let cap = one.utf8.count * 3 + 5   // lands mid-line
        let h = try AuditHistoryReader.read(url, maxBytes: cap)
        XCTAssertTrue(h.truncatedHead)
        XCTAssertEqual(h.entries.count, 3)
        XCTAssertEqual(h.malformedLines, 0)
        XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8), "reader must not modify the file")
    }

    // MARK: CSV

    /// Minimal RFC 4180 parser for the round-trip check.
    private func parseCSV(_ s: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let chars = Array(s), n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]
            if quoted {
                if c == "\"" { if i + 1 < n, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false } } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\r\n" || c == "\n" { row.append(field); field = ""; rows.append(row); row = [] }
            else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    func testCSVRoundTripsEveryField() throws {
        let nasty = "/tmp/a,\"b\"\nc"
        let records = [rec(run1, "trashed", bytes: 42, path: nasty, trash: "/Users/u/.Trash/x"),
                       rec(run1, "skipped", reasons: ["keepTier", "inUse"]),
                       rec(run2, "failed", error: "boom, \"bad\"", command: ["/usr/bin/tool", "clean"], exit: 3)]
        let text = try records.map { try line($0) }.joined(separator: "\n") + "\n"
        let h = AuditHistoryReader.parse(Data(text.utf8))
        let rows = parseCSV(AuditCSV.export(h))
        XCTAssertEqual(rows[0], AuditCSV.header)
        XCTAssertEqual(rows.count, 4)
        let idx = Dictionary(uniqueKeysWithValues: AuditCSV.header.enumerated().map { ($1, $0) })
        for (r, row) in zip(records, rows.dropFirst()) {
            XCTAssertEqual(row[idx["runID"]!], r.runID.uuidString)
            XCTAssertEqual(row[idx["result"]!], r.result)
            XCTAssertEqual(row[idx["action"]!], "trash")
            XCTAssertEqual(row[idx["bytes"]!], String(r.bytes))
            XCTAssertEqual(row[idx["path"]!], r.path)
            XCTAssertEqual(row[idx["trashPath"]!], r.trashPath ?? "")
            XCTAssertEqual(row[idx["ruleID"]!], r.ruleID)
            XCTAssertEqual(row[idx["tool"]!], "claude")
            XCTAssertEqual(row[idx["reasons"]!], r.reasons.joined(separator: ";"))
            XCTAssertEqual(row[idx["error"]!], r.error ?? "")
            XCTAssertEqual(row[idx["command"]!], r.command?.joined(separator: " ") ?? "")
            XCTAssertEqual(row[idx["exitStatus"]!], r.exitStatus.map(String.init) ?? "")
            XCTAssertEqual(ISO8601DateFormatter.withFraction.date(from: row[idx["timestamp"]!]), r.timestamp)
        }
    }

    func testCSVQuitRowsAndUnknownSkipped() throws {
        let text = try line(quit("result")) + "\n" + #"{"schemaVersion":3}"# + "\n"
        let rows = parseCSV(AuditCSV.export(AuditHistoryReader.parse(Data(text.utf8))))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1][3], "quit.graceful")
        XCTAssertEqual(rows[1][2], "quit")
    }

    // MARK: Trash policy

    func testTrashPolicy() {
        let home = "/Users/u"
        XCTAssertTrue(TrashRevealPolicy.isInsideTrash("/Users/u/.Trash/x", home: home))
        XCTAssertTrue(TrashRevealPolicy.isInsideTrash("/Volumes/D/.Trashes/501/x", home: home, uid: 501))
        XCTAssertFalse(TrashRevealPolicy.isInsideTrash("/Volumes/D/.Trashes/502/x", home: home, uid: 501))
        XCTAssertFalse(TrashRevealPolicy.isInsideTrash("/Users/u/.Trash", home: home))
        XCTAssertFalse(TrashRevealPolicy.isInsideTrash("/Users/u/.Trash/../Documents/x", home: home))
        XCTAssertFalse(TrashRevealPolicy.isInsideTrash("/Users/u/Documents/x", home: home))
        XCTAssertFalse(TrashRevealPolicy.isInsideTrash("/Users/u/.Trashy/x", home: home))
    }

    func testExistsNowDoesNotFollowSymlinks() throws {
        let link = dir.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: dir.appendingPathComponent("gone").path)
        XCTAssertTrue(TrashRevealPolicy.existsNow(link.path))
        XCTAssertFalse(TrashRevealPolicy.existsNow(dir.appendingPathComponent("gone").path))
    }
}

private extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}
