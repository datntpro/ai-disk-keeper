import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class StartupItemsTests: XCTestCase {
    static func item(_ name: String, _ domain: StartupItem.Domain = .userAgent, state: StartupItem.ProgramState = .present,
                     label: String? = nil, schedules: [StartupItem.Schedule] = [.atLoad], signer: AppSource? = nil,
                     load: StartupItem.LoadState = .unknown, program: String? = "/bin/echo") -> StartupItem {
        StartupItem(plistPath: "/h/Library/LaunchAgents/\(name).plist", label: label ?? name, program: program,
                    schedules: schedules, domain: domain, programState: state, signer: signer, loadState: load,
                    isHomebrewService: (label ?? name).hasPrefix("homebrew.mxcl."), allocatedBytes: 4096, logicalBytes: 300)
    }

    static var sample: [StartupItem] {
        [item("com.a.broken", state: .missing, schedules: [.atLoad, .interval(seconds: 14_400)], program: "/Gone.app/x"),
         item("com.a.valid", signer: .developerID(teamID: "TEAM1"), load: .running(pid: 5)),
         item("homebrew.mxcl.adkqa"),
         item("com.vendor.daemon", .systemDaemon, state: .missing),
         item("com.vendor.agent", .systemAgent),
         StartupItem(plistPath: "/h/Library/LaunchAgents/damaged.plist", label: nil, program: nil, domain: .userAgent,
                     programState: .unresolvable, parseError: "bad")]
    }

    func makeModel(_ items: [StartupItem] = StartupItemsTests.sample) -> StartupItemsModel {
        StartupItemsModel(inventory: { StartupInventory(items: items, warnings: []) })
    }

    func testFilterCounts() async {
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.userCount, 4)
        XCTAssertEqual(model.systemCount, 2)
        XCTAssertEqual(model.brokenCount, 2)
        model.filter = .broken
        XCTAssertEqual(model.rows.map(\.displayName), ["com.a.broken", "com.vendor.daemon"])
        model.filter = .system
        XCTAssertEqual(model.rows.count, 2)
        model.filter = .user
        XCTAssertEqual(model.rows.count, 4)
    }

    func testSelectionRefusesNonRemovableItems() async {
        let model = makeModel()
        await model.refresh()
        for item in model.items { model.selection.setSelected(model.scanItem(for: item), true) }
        XCTAssertEqual(model.selectedItems.map(\.displayName), ["com.a.broken"])
    }

    func testReviewHandsOnlyTrashStartupItemsToTheEngine() async {
        let model = makeModel()
        await model.refresh()
        let engine = FakeCleanupEngine()
        let coordinator = CleanupCoordinator(holder: CleanupEngineHolder(engine: engine))
        for item in model.items { model.selection.setSelected(model.scanItem(for: item), true) }
        model.review(using: coordinator)
        for _ in 0..<600 where await engine.issuedPlans.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        let entries = await engine.issuedPlans.first?.entries.map(\.item) ?? []
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.cleanupMethod, .trash)
        XCTAssertEqual(entries.first?.category, .startupItem)
        XCTAssertEqual(entries.first?.ruleID, "startup.brokenAgent")
    }

    func testRemoveTrashedUpdatesCounts() async {
        let model = makeModel()
        await model.refresh()
        let broken = model.items[0]
        model.selection.setSelected(model.scanItem(for: broken), true)
        model.inspectedID = broken.id
        model.removeTrashed([model.scanItem(for: broken).id])
        XCTAssertEqual(model.userCount, 3)
        XCTAssertEqual(model.brokenCount, 1)
        XCTAssertTrue(model.selection.selectedIDs.isEmpty)
        XCTAssertNil(model.inspectedID)
    }

    func testSortByStatusAndItem() async {
        let model = makeModel()
        await model.refresh()
        model.sortOrder = [StartupItemComparator(column: .item, order: .reverse)]
        XCTAssertEqual(model.rows.first?.displayName, "homebrew.mxcl.adkqa")
        model.sortOrder = [StartupItemComparator(column: .status)]
        XCTAssertEqual(model.rows.count, 6)
    }

    func testFailedInventoryShowsFailedPhase() async {
        struct Boom: Error {}
        let model = StartupItemsModel(inventory: { throw Boom() })
        await model.refresh()
        guard case .failed = model.phase else { return XCTFail("expected failed") }
    }

    func testActionsUseSeams() async {
        let model = makeModel()
        await model.refresh()
        var copied: [String] = []
        var opened: [URL] = []
        model.copyToPasteboard = { copied.append($0) }
        model.openURL = { opened.append($0) }
        model.copyBrewCommand(model.items[2])
        model.copyBrewCommand(model.items[0])      // not a Homebrew service: nothing copied
        model.copyLabel(model.items[0])
        model.openLoginItemsSettings()
        XCTAssertEqual(copied, ["brew services stop adkqa", "com.a.broken"])
        XCTAssertEqual(opened, [SystemSettingsLinks.loginItems])
    }

    func testScheduleFormatter() {
        let item = Self.item("x", schedules: [.atLoad, .interval(seconds: 14_400)])
        XCTAssertEqual(StartupCopy.runs(item), "at login, every 4 h")
        XCTAssertEqual(StartupCopy.runs(Self.item("x", schedules: [.keepAlive])), "keep alive")
        XCTAssertEqual(StartupCopy.runs(Self.item("x", schedules: [.onDemand])), "on demand")
        XCTAssertEqual(StartupCopy.shortDuration(90), "90 s")
        XCTAssertEqual(StartupCopy.shortDuration(5_400), "90 min")
        XCTAssertTrue(StartupCopy.runs(item, spoken: true).contains("4 hours"))
        L10n.withLanguage(.vi) {
            XCTAssertEqual(StartupCopy.runs(item), "khi đăng nhập, mỗi 4 giờ")
            XCTAssertEqual(StartupCopy.runs(Self.item("x", schedules: [.keepAlive])), "luôn chạy")
        }
    }

    func testDamagedRowHasRunsInItsA11yLabel() {
        let damaged = Self.sample[5]
        XCTAssertFalse(StartupCopy.runs(damaged).isEmpty)
        XCTAssertFalse(StartupCopy.rowA11y(damaged).contains(", ,"))
    }

    func testStatusText() {
        XCTAssertEqual(StartupCopy.status(Self.sample[0]), "Program missing · Safe to remove")
        XCTAssertEqual(StartupCopy.status(Self.sample[1]), "Running · TEAM1 (signed)")
        XCTAssertEqual(StartupCopy.status(Self.sample[2]), "Use brew services stop adkqa")
        XCTAssertTrue(StartupCopy.status(Self.sample[3]).hasSuffix("View only"))
        XCTAssertEqual(StartupCopy.status(Self.sample[5]), "Can't be read (damaged file)")
        L10n.withLanguage(.vi) {
            XCTAssertEqual(StartupCopy.status(Self.sample[0]), "Thiếu chương trình · An toàn để xóa")
            XCTAssertEqual(StartupCopy.status(Self.sample[5]), "Không đọc được (tệp hỏng)")
        }
    }

    func testViewsRenderInEachPhase() async {
        let engine = FakeCleanupEngine()
        let coordinator = CleanupCoordinator(holder: CleanupEngineHolder(engine: engine))
        let ready = makeModel()
        await ready.refresh()
        ready.inspectedID = ready.items[0].id
        struct Boom: Error {}
        let failed = StartupItemsModel(inventory: { throw Boom() })
        await failed.refresh()
        let idle = makeModel()
        for model in [ready, failed, idle] {
            let views: [AnyView] = [AnyView(StartupItemsView(model: model, coordinator: coordinator)),
                                    AnyView(StartupItemsInspector(model: model))]
            for v in views { XCTAssertNotNil(ImageRenderer(content: v.frame(width: 900, height: 500)).cgImage) }
        }
        ready.filter = .broken
        XCTAssertNotNil(ImageRenderer(content: StartupItemsView(model: ready, coordinator: coordinator).frame(width: 900, height: 500)).cgImage)
    }
}
