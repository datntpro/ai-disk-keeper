import DiskKeeperCore
import Foundation
import Testing
@testable import AIDiskKeeperUI

@MainActor
@Suite struct HistoryModelTests {
    private func rec(_ run: UUID, _ result: String, bytes: Int64, trash: String? = nil) -> AuditRecord {
        AuditRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_000), runID: run, itemID: "i", path: "/x", bytes: bytes,
                    action: .trash, result: result, trashPath: trash, ruleID: "r", tool: "npm", reasons: [], error: nil)
    }

    private func model(_ recs: [AuditRecord], exists: @escaping (String) -> Bool) async -> HistoryModel {
        let lines = recs.map { String(decoding: try! DiskKeeperJSON.makeEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        let m = HistoryModel(logURL: URL(fileURLWithPath: "/nonexistent/audit.jsonl"), home: "/Users/t", uid: 501, exists: exists,
                             load: { _ in AuditHistoryReader.parse(Data(lines.utf8)) })
        await m.refresh()
        return m
    }

    @Test func lifetimeAndGrouping() async {
        let a = UUID(), b = UUID()
        let m = await model([rec(a, "trashed", bytes: 10), rec(a, "trashed", bytes: 5), rec(b, "skipped", bytes: 99)], exists: { _ in true })
        #expect(m.lifetimeReclaimed == 15)
        #expect(m.runs.count == 2)
        #expect(m.phase == .ready)
    }

    @Test func revealOnlyInsideTrashAndExisting() async {
        let a = UUID()
        let inTrash = rec(a, "trashed", bytes: 1, trash: "/Users/t/.Trash/x")
        let volTrash = rec(a, "trashed", bytes: 1, trash: "/.Trashes/501/x")
        let outside = rec(a, "trashed", bytes: 1, trash: "/Users/t/Documents/x")
        let dotdot = rec(a, "trashed", bytes: 1, trash: "/Users/t/.Trash/../Documents/x")
        let none = rec(a, "skipped", bytes: 1)
        var present = true
        let m = await model([inTrash], exists: { _ in present })
        #expect(m.canRevealInTrash(inTrash) && m.canRevealInTrash(volTrash))
        #expect(!m.canRevealInTrash(outside) && !m.canRevealInTrash(dotdot) && !m.canRevealInTrash(none))
        present = false
        let m2 = await model([inTrash], exists: { _ in false })
        #expect(!m2.canRevealInTrash(inTrash))
    }

    @Test func loadFailureShowsFailedPhase() async {
        struct E: Error {}
        let m = HistoryModel(logURL: URL(fileURLWithPath: "/x"), home: "/Users/t", load: { _ in throw E() })
        await m.refresh()
        if case .failed = m.phase {} else { Issue.record("expected failed") }
    }
}
