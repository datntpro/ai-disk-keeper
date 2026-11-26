import DiskKeeperCore
import AppKit
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class UninstallerRenderTests: XCTestCase {
    private func model(running: Set<String> = []) async -> UninstallerModel {
        let apps = [UninstallFix.slide, UninstallFix.app("Notely", size: 2000),
                    UninstallFix.app("Safari", size: 9000, reason: .apple, source: .apple, location: .system)]
        let items = UninstallFix.slideItems + [UninstallFix.sharedItem] + UninstallFix.orphanItems
        let m = UninstallerModel(inventory: { AppInventory(apps: apps, warnings: [], scannedRoots: []) },
                                 leftovers: { _ in UninstallFix.result(items) }, runningApps: { running }, home: "/h")
        m.load()
        await m.settle()
        return m
    }

    private func render(_ view: some View, _ what: String) {
        for scheme in [ColorScheme.light, .dark] {
            let r = ImageRenderer(content: view.frame(width: 900, height: 640).environment(\.colorScheme, scheme).background(.adkBg))
            XCTAssertNotNil(r.cgImage, "\(what) \(scheme)")
        }
    }

    func testListDetailAndTabsRender() async {
        let c = CleanupCoordinator(holder: CleanupEngineHolder())
        let m = await model(running: ["com.test.notely"])
        render(UninstallerView(model: m, coordinator: c), "no selection")
        m.select(UninstallFix.slide)
        render(UninstallerView(model: m, coordinator: c), "detail")
        m.tab = .orphans
        m.toggleOrphan(m.orphans[0])
        render(UninstallerView(model: m, coordinator: c), "orphans")
        let empty = await model()
        empty.tab = .orphans
        render(UninstallOrphansView(model: empty, coordinator: c), "orphans ticked")
    }

    func testStatesAndGuidanceCardsRender() async {
        let c = CleanupCoordinator(holder: CleanupEngineHolder())
        let loading = UninstallerModel(inventory: { try await Task.sleep(nanoseconds: 60_000_000_000); throw CancellationError() },
                                       leftovers: { _ in UninstallFix.result([]) }, runningApps: { [] })
        loading.load()
        render(UninstallerView(model: loading, coordinator: c), "loading")
        struct Boom: Error {}
        let failed = UninstallerModel(inventory: { throw Boom() }, leftovers: { _ in UninstallFix.result([]) }, runningApps: { [] })
        failed.load(); await failed.settle()
        render(UninstallerView(model: failed, coordinator: c), "failed")
        let m = await model(running: ["com.test.notely"])
        for app in m.apps { m.select(app); render(UninstallerView(model: m, coordinator: c), app.name) }
        let guidance: [UninstallGuidance] = [.appManagement(bundleID: "x"), .requiresAdmin(bundleID: "x"), .running(name: "A"),
                                             .locked(.apple), .locked(.notOwnedByUser)]
        for g in guidance { render(UninstallGuidanceCard(guidance: g, app: UninstallFix.slide, model: m).padding(), "\(g)") }
        m.search = "zzz"
        render(UninstallAppList(model: m), "no match")
    }

    /// Regression: HSplitView crashed on load with apps listed. The ready state at a real window width must render.
    func testReadyStateWithAppsRendersAtWindowWidth() async {
        let c = CleanupCoordinator(holder: CleanupEngineHolder())
        let m = await model()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertFalse(m.apps.isEmpty)
        let host = NSHostingView(rootView: UninstallerView(model: m, coordinator: c).frame(width: 1000, height: 680))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 680)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        for selected in [false, true] {
            if selected { m.select(UninstallFix.slide) }
            let r = ImageRenderer(content: UninstallerView(model: m, coordinator: c).frame(width: 1000, height: 680).background(.adkBg))
            XCTAssertNotNil(r.cgImage, "ready selected=\(selected)")
        }
    }
}
