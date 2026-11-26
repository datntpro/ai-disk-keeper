import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class OverviewRenderTests: XCTestCase {
    private func storage() async -> StorageModel {
        let m = StorageModel(load: { StorageFix.overview() })
        m.refresh()
        await m.settle()
        return m
    }

    private func view(_ rig: CareRig, _ storage: StorageModel) -> some View {
        OverviewView(care: rig.model, scan: rig.scan, storage: storage,
                     cleanup: CleanupCoordinator(holder: CleanupEngineHolder(engine: FakeCleanupEngine())),
                     selection: SelectionModel(), open: { _ in }, inspect: { _ in }, showWarnings: {})
    }

    private func render(_ view: some View, scheme: ColorScheme, size: DynamicTypeSize = .large, _ what: String) {
        let r = ImageRenderer(content: view.frame(width: 860, height: 1000).environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, size).background(.adkBg))
        XCTAssertNotNil(r.cgImage, what)
    }

    func testAllFourPhasesRenderLightAndDark() async {
        let storage = await storage()
        let ai = ModuleSummary(module: .aiTools, safeBytes: 5_000, reviewBytes: 2_000, keepBytes: 100, itemCount: 7)
        let items = [ItemFixtures.item("cache", size: 5_000), ItemFixtures.item("logs", tier: .review, size: 2_000)]

        let before = CareRig()
        for s in [ColorScheme.light, .dark] { render(view(before, storage), scheme: s, "before") }

        let scanning = CareRig()
        await scanning.begin()
        await scanning.send(CareFix.started(), .stageStarted(.rules), .stageProgress(.rules, 0.4), .item(.rules, items[0]))
        await scanning.settle()
        XCTAssertEqual(scanning.model.phase, .scanning)
        for s in [ColorScheme.light, .dark] { render(view(scanning, storage), scheme: s, "scanning") }

        let results = CareRig()
        await results.begin()
        await results.send(CareFix.started(), .stageStarted(.rules), .scanEvent(.rules, CareFix.ruleStarted),
                           .scanEvent(.rules, .itemFound(items[0])), .scanEvent(.rules, .itemFound(items[1])),
                           .item(.rules, items[0]), .item(.rules, items[1]), .stageFinished(.rules, [ai]),
                           .finished(CareFix.report(safe: 5_000, review: 2_000, keep: 100, summaries: [.aiTools: ai],
                                                    growth: CareGrowth(since: ItemFixtures.t0, aiToolsDelta: 500_000_000, perTool: [:]))))
        await results.waitUntil { results.model.phase == .results }
        XCTAssertEqual(results.model.biggestWins.count, 2)
        for s in [ColorScheme.light, .dark] { render(view(results, storage), scheme: s, "results") }
        render(view(results, storage), scheme: .light, size: .accessibility3, "results at 200 % text")

        let stopped = CareRig()
        await stopped.begin()
        await stopped.send(CareFix.started(), .stageStarted(.rules))
        stopped.model.stop()
        await stopped.waitUntil { stopped.model.phase == .stopped }
        for s in [ColorScheme.light, .dark] { render(view(stopped, storage), scheme: s, "stopped") }
    }

    func testHeroAtLargeTextRenders() async {
        let storage = await storage()
        let rig = CareRig()
        let hero = CareHero(model: rig.model, storage: storage, showFirstRunNote: true, onReview: {}, onCleanSafe: {})
        render(hero, scheme: .light, size: .accessibility3, "hero")
        render(hero, scheme: .dark, size: .xxxLarge, "hero")
    }

    func testRingIsStaticUnderReduceMotion() {
        XCTAssertEqual(CareHero.ringStyle(reduceMotion: true), .static)
        XCTAssertEqual(CareHero.ringStyle(reduceMotion: false), .sweep)
        XCTAssertNil(StrataMotion.animation(reduceMotion: true))
    }

    func testHeroNumbersUseNumericTextTransition() throws {
        let file = URL(fileURLWithPath: #filePath)
        let root = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AIDiskKeeperUI/Modules/Overview/CareHero.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".contentTransition(.numericText())"))
        XCTAssertTrue(source.contains("StrataMotion.animation(reduceMotion:"))
    }

    func testWindowHidesTheStrataBarUntilStorageIsMeasured() {
        let empty = StorageModel(load: { StorageFix.overview() })
        XCTAssertNil(empty.totalBytes)
        let rig = CareRig()
        let bar = OverviewStrata(storage: empty, scan: rig.scan, care: rig.model)
        XCTAssertNil(ImageRenderer(content: bar.frame(width: 400)).cgImage)
    }
}
