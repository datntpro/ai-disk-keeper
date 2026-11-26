import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class MenuBarSettingsTests: XCTestCase {
    private func model() -> (SettingsModel, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("adk-t50-s-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (SettingsModel(store: SettingsStore(fileURL: url), environment: .current(), probe: { .unknown }), url)
    }

    func testSettersPersistAndReload() {
        let (m, url) = model()
        m.setMenuBarStyle(.ridge)
        m.setMenuBarRefresh(seconds: 9)
        m.setNetworkUnits(.bits)
        m.setShowsTopProcesses(true)
        m.setHistoryMinutes(5)
        m.setMetric(.cpu, inMenuBar: true)
        m.setMetric(.memory, monitored: false)
        m.setMetric(.disk, monitored: false)
        m.moveMetric(.network, by: -1)
        let reloaded = SettingsModel(store: SettingsStore(fileURL: url), environment: .current(), probe: { .unknown }).settings
        XCTAssertEqual(reloaded.menuBarStyle, .ridge)
        XCTAssertEqual(reloaded.menuBarRefreshSeconds, 10)
        XCTAssertEqual(reloaded.networkUnits, .bits)
        XCTAssertTrue(reloaded.popoverShowsTopProcesses)
        XCTAssertEqual(reloaded.popoverHistoryMinutes, 5)
        XCTAssertEqual(reloaded.menuBarMetrics, [.cpu])
        XCTAssertEqual(reloaded.monitorDisabled, [.memory])
        XCTAssertEqual(reloaded.monitorOrder, [.disk, .cpu, .network, .memory])
    }

    func testMoveFromDragOffsets() {
        let (m, _) = model()
        m.moveMetrics(from: IndexSet(integer: 3), to: 1)
        XCTAssertEqual(m.settings.monitorOrder, [.disk, .network, .cpu, .memory])
    }

    func testTheSettingsTabRendersWithTheItemOnAndOff() {
        for on in [true, false] {
            for language in [AppLanguage.en, .vi] {
                L10n.apply(language)
                defer { L10n.apply(.en) }
                let (m, _) = model()
                m.setShowMenuBarItem(on)
                m.setMetric(.cpu, inMenuBar: true); m.setMetric(.network, inMenuBar: true); m.setMetric(.memory, inMenuBar: true)
                m.setMenuBarShowsFreeSpace(true)
                for scheme in [ColorScheme.light, .dark] {
                    XCTAssertNotNil(ImageRenderer(content: MenuBarSettingsView(model: m).frame(width: 520, height: 700)
                        .environment(\.colorScheme, scheme)).cgImage, "on=\(on) \(language) \(scheme)")
                }
            }
        }
    }
}
