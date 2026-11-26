import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class HistoryModelTests: XCTestCase {
    private final class FakeFinder: FinderRevealing {
        var revealed: [URL] = []
        func reveal(_ url: URL) { revealed.append(url) }
    }

    private func rec(_ run: UUID, _ result: String, bytes: Int64, trash: String?) -> AuditRecord {
        AuditRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_000), runID: run, itemID: "i", path: "/p", bytes: bytes,
                    action: .trash, result: result, trashPath: trash, ruleID: "r", tool: "claude", reasons: [], error: nil)
    }

    private func model(records: [AuditRecord], exists: @escaping @Sendable (String) -> Bool = { _ in true }) throws -> HistoryModel {
        let text = try records.map { String(decoding: try DiskKeeperJSON.makeEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")
        let history = AuditHistoryReader.parse(Data(text.utf8))
        return HistoryModel(logURL: URL(fileURLWithPath: "/nonexistent/audit.jsonl"), home: "/Users/u",
                            reader: { _ in history }, trashProbe: exists)
    }

    func testLifetimeCounterAndGrouping() async throws {
        let a = UUID(), b = UUID()
        let m = try model(records: [rec(a, "trashed", bytes: 5, trash: nil), rec(a, "skipped", bytes: 99, trash: nil),
                                    rec(b, "deleted", bytes: 7, trash: nil)])
        XCTAssertEqual(m.phase, .idle)
        m.load()
        await m.settle()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.runs.count, 2)
        XCTAssertEqual(m.lifetimeReclaimed, 12)
    }

    func testRevealOnlyWhenInsideTrashAndPresent() async throws {
        let id = UUID()
        let inTrash = rec(id, "trashed", bytes: 1, trash: "/Users/u/.Trash/x")
        let outside = rec(id, "trashed", bytes: 1, trash: "/Users/u/Documents/x")
        let none = rec(id, "trashed", bytes: 1, trash: nil)
        let present = try model(records: [inTrash])
        XCTAssertTrue(present.canRevealInTrash(inTrash))
        XCTAssertFalse(present.canRevealInTrash(outside))
        XCTAssertFalse(present.canRevealInTrash(none))
        let gone = try model(records: [inTrash], exists: { _ in false })
        XCTAssertFalse(gone.canRevealInTrash(inTrash))
        let finder = FakeFinder()
        gone.finder = finder
        gone.revealInTrash(inTrash)
        XCTAssertTrue(finder.revealed.isEmpty)
        present.finder = finder
        present.revealInTrash(inTrash)
        XCTAssertEqual(finder.revealed.map(\.path), ["/Users/u/.Trash/x"])
    }

    func testReadFailureShowsFailedPhase() async {
        struct Boom: Error {}
        let m = HistoryModel(logURL: URL(fileURLWithPath: "/x"), home: "/h", reader: { _ in throw Boom() })
        m.load()
        await m.settle()
        XCTAssertEqual(m.phase, .failed)
    }
}
