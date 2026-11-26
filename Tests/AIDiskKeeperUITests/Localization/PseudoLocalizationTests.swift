import AppKit
import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

/// Size assertions (no image snapshots): key screens must lay out inside their minimum frame under pseudo-localization
/// (~40 % longer English) and under Vietnamese. Text wraps rather than clips, so we also bound the height growth.
@MainActor
final class PseudoLocalizationTests: XCTestCase {
    private let env = PathEnvironment(home: "/Users/tester", temporaryDirectory: "/tmp")
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("Pseudo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        L10n.apply(.en)
        try? FileManager.default.removeItem(at: dir)
    }

    private func settingsModel() -> SettingsModel {
        SettingsModel(store: SettingsStore(fileURL: dir.appendingPathComponent("s.json")), environment: env,
                      availableTools: [ToolChoice(id: "cursor", name: "Cursor")], probe: { .notGranted })
    }

    /// Fitting size of `view` when offered exactly `width`.
    private func fit<V: View>(_ view: V, width: CGFloat) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func assertFits<V: View>(_ name: String, minWidth: CGFloat, maxGrowth: CGFloat = 2.2,
                                     _ make: () -> V, line: UInt = #line) {
        let base = L10n.withLanguage(.en) { fit(make(), width: minWidth) }
        for (label, apply) in [("pseudo", { L10n.applyPseudo() }), ("vi", { L10n.apply(.vi) })] as [(String, () -> Void)] {
            apply()
            let size = fit(make(), width: minWidth)
            XCTAssertLessThanOrEqual(size.width, minWidth + 1, "\(name) [\(label)] is wider than its minimum frame", line: line)
            XCTAssertGreaterThan(size.height, 0, "\(name) [\(label)]", line: line)
            if base.height > 0 {
                XCTAssertLessThanOrEqual(size.height, base.height * maxGrowth + 40,
                                         "\(name) [\(label)] grows too much (\(size.height) vs \(base.height))", line: line)
            }
        }
        L10n.apply(.en)
    }

    func testPseudoTransformKeepsPlaceholdersAndWraps() {
        XCTAssertEqual(L10n.pseudoLocalize("Scan"), "[Šçåñ ~~]")
        XCTAssertTrue(L10n.pseudoLocalize("Moving to Trash… 3 of 10").hasPrefix("["))
        L10n.applyPseudo()
        defer { L10n.apply(.en) }
        XCTAssertEqual(loc("overview.itemCount", "\(7) items"), L10n.pseudoLocalize("7 items"))
    }

    func testOnboarding() {
        assertFits("OnboardingView", minWidth: 560) {
            OnboardingView(settings: settingsModel(), onboarding: OnboardingModel(settings: settingsModel()) {}, dismiss: {})
        }
    }

    func testSettingsTabs() {
        assertFits("GeneralSettingsView", minWidth: 560) { GeneralSettingsView(model: settingsModel()) }
        assertFits("ScanScopeSettingsView", minWidth: 560) { ScanScopeSettingsView(model: settingsModel()) }
        assertFits("ToolsSettingsView", minWidth: 560) { ToolsSettingsView(model: settingsModel()) }
    }

    func testItemDetail() {
        let item = ItemFixtures.item("Conversation transcripts", tier: .review, size: 5_000_000)
        assertFits("ItemDetailView", minWidth: 260) { ItemDetailView(item: item) }
    }

    func testCleanupReview() {
        let items = [ItemFixtures.item("a", tier: .safe), ItemFixtures.item("b", tier: .review)]
        let entries = [CleanupPlanEntry(item: items[0], action: .trash, blockers: [], fingerprint: nil),
                       CleanupPlanEntry(item: items[1], action: .trash, blockers: [.keepTier], fingerprint: nil)]
        let plan = CleanupPlan(createdAt: Date(), entries: entries)
        assertFits("CleanupReviewSheet", minWidth: 520) {
            CleanupReviewSheet(plan: plan, notice: nil, onRecheck: {}, onCancel: {}, onConfirm: {})
        }
    }

    func testWarningsAndEmptyState() {
        let w = [ScanWarning(kind: .permissionDenied, path: "/x", message: "m", code: .pathError(errno: EACCES))]
        assertFits("WarningsView", minWidth: 560) { WarningsView(warnings: w).frame(height: 300) }
        assertFits("EmptyStateView", minWidth: 560) { EmptyStateView() }
    }
}
