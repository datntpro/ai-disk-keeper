import DiskKeeperCore
import AppKit
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class UninstallerRenderTests: XCTestCase {
    private func model(running: Set<InstalledApp.ID> = []) async -> UninstallerModel {
        let apps = [UninstallFix.slide, UninstallFix.app("Notely", size: 2000),
                    UninstallFix.app("Safari", size: 9000, reason: .apple, source: .apple, location: .system)]
        let items = UninstallFix.slideItems + [UninstallFix.sharedItem] + UninstallFix.orphanItems
        let m = UninstallerModel(inventory: { AppInventory(apps: apps, warnings: [], scannedRoots: []) },
                                 leftovers: { _ in UninstallFix.result(items) }, processes: fake(running), home: "/h")
        m.load()
        await m.settle()
        return m
    }

    private func fake(_ running: Set<InstalledApp.ID>) -> FakeAppProcessController {
        let f = FakeAppProcessController()
        for id in running { f.states[id] = AppRunState(instances: [FakeAppProcessController.instance()]) }
        return f
    }

    private func render(_ view: some View, _ what: String) {
        for scheme in [ColorScheme.light, .dark] {
            let r = ImageRenderer(content: view.frame(width: 900, height: 640).environment(\.colorScheme, scheme).background(.adkBg))
            XCTAssertNotNil(r.cgImage, "\(what) \(scheme)")
        }
    }

    func testListDetailAndTabsRender() async {
        let c = CleanupCoordinator(holder: CleanupEngineHolder())
        let m = await model(running: [UninstallFix.app("Notely", size: 2000).id])
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
                                       leftovers: { _ in UninstallFix.result([]) }, processes: FakeAppProcessController())
        loading.load()
        render(UninstallerView(model: loading, coordinator: c), "loading")
        struct Boom: Error {}
        let failed = UninstallerModel(inventory: { throw Boom() }, leftovers: { _ in UninstallFix.result([]) }, processes: FakeAppProcessController())
        failed.load(); await failed.settle()
        render(UninstallerView(model: failed, coordinator: c), "failed")
        let m = await model(running: [UninstallFix.app("Notely", size: 2000).id])
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

    /// Laid-out size of a view proposed `width` wide (what the user would see, not just "an image came out").
    private func measured(_ view: some View, width: CGFloat) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 2000)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    func testQuitCardsRenderInBothLanguages() async {
        let m = await model(running: [UninstallFix.app("Notely", size: 2000).id])
        let notely = UninstallFix.app("Notely", size: 2000)
        let cards: [UninstallGuidance] = [
            .running(name: "Notely", quit: nil, background: [], otherUser: false, canQuit: true),
            .running(name: "Notely", quit: .quitting), .running(name: "Notely", quit: .stuck, canQuit: true),
            .running(name: "Notely", quit: .failed, canQuit: true), .running(name: "Notely", quit: .relaunched),
            .running(name: "Notely", quit: .backgroundRemains, background: ["adkqa-bg (77)"]),
            .runningUnknown(name: "Notely"), .selfApp, .quitDone(name: "Notely")]
        for lang in [AppLanguage.en, .vi] {
            L10n.withLanguage(lang) {
                for g in cards {
                    let r = ImageRenderer(content: UninstallGuidanceCard(guidance: g, app: notely, model: m).padding().frame(width: 380).background(.adkBg))
                    XCTAssertNotNil(r.cgImage, "\(lang) \(g)")
                }
            }
        }
    }

    /// #111: the action bar is at most two rows (summary up to two lines) at a wide window and at the narrowest
    /// detail width, in en and vi. A summary squeezed to one character per line would be several times taller.
    func testActionBarKeepsItsTextReadableAtWideAndMinimumWidthInBothLanguages() async {
        let m = await model()
        let c = CleanupCoordinator(holder: CleanupEngineHolder())
        m.select(UninstallFix.slide)
        for lang in [AppLanguage.en, .vi] {
            L10n.withLanguage(lang) {
                for width in [700.0, 380.0] {
                    let bar = UninstallActionBar(model: m, availability: .available, help: "", coordinator: c)
                    let size = measured(bar, width: width)
                    XCTAssertLessThanOrEqual(size.width, width + 0.5, "bar overflows \(lang) \(width)")
                    XCTAssertLessThanOrEqual(size.height, 80, "bar text squeezed \(lang) \(width)")
                    // The size text alone is never wrapped: its height is one line.
                    let sizeOnly = measured(SizeText(m.tickedBytes, qualifier: .upTo).font(.headline).fixedSize(), width: width)
                    XCTAssertLessThanOrEqual(sizeOnly.height, 24, "size text wraps \(lang)")
                }
            }
        }
    }

    /// F1: the stuck card's text and its three buttons fit a narrow detail column in both languages.
    func testStuckCardTextAndButtonsStayReadableInBothLanguages() async {
        let m = await model(running: [UninstallFix.app("Notely", size: 2000).id])
        let notely = UninstallFix.app("Notely", size: 2000)
        for lang in [AppLanguage.en, .vi] {
            L10n.withLanguage(lang) {
                for width in [700.0, 380.0] {
                    let card = UninstallGuidanceCard(guidance: .running(name: "Notely", quit: .stuck, canQuit: true), app: notely, model: m).padding()
                    let size = measured(card, width: width)
                    XCTAssertLessThanOrEqual(size.width, width + 0.5, "card overflows \(lang) \(width)")
                    XCTAssertLessThanOrEqual(size.height, 200, "card text squeezed \(lang) \(width)")
                }
            }
        }
    }
}
