import AppKit
import DiskKeeperCore
import SwiftUI
import XCTest

@testable import AIDiskKeeperUI

@MainActor
final class WorktreeManagerModelTests: XCTestCase {
    func row(_ name: String, eligible: Bool, processes: [WorktreeProcess] = [], dirty: Bool = false) -> WorktreeRow {
        var git = GitState(path: "/w/\(name)", kind: .linkedWorktree, gitDir: "/g", commonDir: "/g")
        git.workingTree = dirty ? .init(untracked: 2) : .init()
        let facts = WorktreeFacts(worktree: DiscoveredWorktree(path: "/w/\(name)", repoPath: "/r"), git: git, processes: processes)
        let checks = WorktreeCheckID.allCases.map { WorktreeCheck(id: $0, passed: eligible ? true : ($0 == .clean ? false : true), evidence: .allowed) }
        return WorktreeRow(facts: facts, verdict: SafeCleanVerdict(checks: checks, tier: eligible ? .safe : .keep))
    }

    func testFilters() {
        let safe = row("a", eligible: true)
        let busy = row("b", eligible: false, processes: [WorktreeProcess(pid: 1, name: "node", agent: nil)])
        let dirty = row("c", eligible: false, dirty: true)
        XCTAssertEqual([safe, busy, dirty].filter { WorktreeFilter.safe.includes($0) }.map(\.name), ["a"])
        XCTAssertEqual([safe, busy, dirty].filter { WorktreeFilter.inUse.includes($0) }.map(\.name), ["b"])
        XCTAssertEqual([safe, busy, dirty].filter { WorktreeFilter.changes.includes($0) }.map(\.name), ["c"])
        XCTAssertEqual([safe, busy, dirty].filter { WorktreeFilter.all.includes($0) }.count, 3)
    }

    func makeModel(consentStore: GitHubConsentStore = .memory(), on: Bool = false) -> (WorktreeManagerModel, () -> [Bool]) {
        final class Applied: @unchecked Sendable { var values: [Bool] = []; var on: Bool; init(_ o: Bool) { on = o } }
        let applied = Applied(on)
        let consent = GitHubConsentModel(isOn: { applied.on }, store: consentStore, apply: { applied.values.append($0); applied.on = $0 })
        let model = WorktreeManagerModel(settings: { AppSettings() }, consent: consent, makeInventory: { _ in nil })
        return (model, { applied.values })
    }

    func testSelectSafeIsDisabledUntilCleaningExists() {
        XCTAssertFalse(makeModel().0.canSelectSafe)
    }

    func testConsentShownOnceThenRemembered() {
        let store = GitHubConsentStore.memory()
        let (model, applied) = makeModel(consentStore: store)
        model.consent.request(true)
        XCTAssertTrue(model.consent.isSheetShown)
        XCTAssertEqual(applied(), [], "nothing is enabled before the user agrees")
        model.consent.cancel()
        XCTAssertFalse(model.consent.isSheetShown)
        XCTAssertEqual(applied(), [])
        model.consent.request(true)
        model.consent.confirm()
        XCTAssertEqual(applied(), [true])
        model.consent.request(false)
        model.consent.request(true)
        XCTAssertFalse(model.consent.isSheetShown, "the sheet is only shown the first time")
        XCTAssertEqual(applied(), [true, false, true])
    }

    func testRefreshWithoutGitProducesWarningNotCrash() async throws {
        let (model, _) = makeModel()
        model.refresh()
        for _ in 0..<100 where model.phase != .ready { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.result?.warnings.isEmpty ?? true)
    }

    func testSettingsFileCannotBypassConsent() async throws {
        final class Seen: @unchecked Sendable { var useGH: Bool? }
        let seen = Seen()
        var settings = AppSettings()
        settings.useGitHubCLIForPRs = true   // e.g. imported from another Mac's settings.json
        let consent = GitHubConsentModel(isOn: { true }, store: .memory(false), apply: { _ in })
        let model = WorktreeManagerModel(settings: { settings }, consent: consent, makeInventory: { s in seen.useGH = s.useGitHubCLIForPRs; return nil })
        model.refresh()
        for _ in 0..<100 where model.phase != .ready { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(seen.useGH, false)
    }

    /// Regression: the Inventory view crashed (AppKit constraint loop) when loaded while the sidebar was collapsed.
    func testManagerViewLaysOutAtEveryWidth() {
        let model = WorktreeManagerModel(settings: { AppSettings() },
                                         consent: GitHubConsentModel(isOn: { false }, store: .memory(), apply: { _ in }),
                                         makeInventory: { _ in nil })
        let rows = (0..<12).map { row("wt\($0)", eligible: $0 % 2 == 0) }
        model.show(InventoryResult(rows: rows))
        model.selection = rows[0].id
        for width in [420, 700, 1040, 1400] as [CGFloat] {
            let host = NSHostingView(rootView: WorktreeManagerView(model: model).frame(width: width, height: 600))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            for _ in 0..<4 { host.layoutSubtreeIfNeeded() }
            XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1, "width \(width)")
        }
    }
}
