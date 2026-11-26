import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class MenuBarRenderTests: XCTestCase {
    private let gb = StorageFix.gb

    private func make(free: Int64 = 182 * StorageFix.gb) async -> (MenuBarModel, SuiteModel, CareRig) {
        let care = CareRig()
        let env = AppEnvironment(pathEnvironment: PathEnvironment(home: "/Users/tester", temporaryDirectory: "/tmp"),
                                 makeScanEngine: { FakeScanEngine(.scripted([])) })
        let suite = SuiteModel(env: env)
        let storage = StorageModel(load: { StorageFix.overview(important: free) })
        storage.refresh()
        await storage.settle()
        let name = "T47-render-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let model = MenuBarModel(storage: storage, care: care.model, scan: care.scan, settings: env.settings,
                                 notifier: SilentLowSpaceNotifier(), defaults: UserDefaults(suiteName: name)!)
        return (model, suite, care)
    }

    private func render(_ view: some View, _ what: String) {
        for scheme in [ColorScheme.light, .dark] {
            let r = ImageRenderer(content: view.environment(\.colorScheme, scheme))
            XCTAssertNotNil(r.cgImage, "\(what) \(scheme)")
        }
    }

    func testPopoverRendersBeforeScanAfterScanAndLowSpace() async {
        let (before, suite, _) = await make()
        render(MenuBarPopover(model: before, suite: suite), "before scan")

        let (after, suite2, rig) = await make()
        await rig.begin()
        let items = [ItemFixtures.item("a", size: 5 * gb), ItemFixtures.item("b", tool: .cursor, size: gb)]
        let growth = CareGrowth(since: ItemFixtures.t0, aiToolsDelta: 3 * gb, perTool: [:])
        await rig.send(CareFix.started(), .scanEvent(.rules, .finished(ItemFixtures.result(items))),
                       .finished(CareFix.report(safe: 6 * gb, summaries: [.aiTools: ModuleSummary(module: .aiTools, safeBytes: 6 * gb)],
                                                growth: growth)))
        await rig.settle()
        render(MenuBarPopover(model: after, suite: suite2), "after scan")

        let (low, suite3, _) = await make(free: 20 * gb)
        render(MenuBarPopover(model: low, suite: suite3), "low space")
        render(MenuBarLabel(model: low), "label")
    }

    func testLowSpaceBodyFormatsInBothLanguages() {
        for language in [AppLanguage.en, .vi] {
            L10n.apply(language)
            defer { L10n.apply(.en) }
            let body = MenuBarCopy.lowSpaceBody(free: "20 GB", percent: "4")
            XCTAssertTrue(body.contains("20 GB"), body)
            XCTAssertTrue(body.contains("4 %"), body)
            XCTAssertFalse(body.contains("%%"), body)
        }
    }

    func testRootViewStillBuildsFromAnEnvironment() {
        let env = AppEnvironment(pathEnvironment: PathEnvironment(home: "/Users/tester", temporaryDirectory: "/tmp"),
                                 makeScanEngine: { FakeScanEngine(.scripted([])) })
        _ = RootView(env: env)
    }
}
