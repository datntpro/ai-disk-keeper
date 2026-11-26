import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class ModuleRegistryTests: XCTestCase {
    func testProvidersAreAllModulesInFixedOrder() {
        let ids = ModuleRegistry.providers.map { $0.descriptor.id }
        XCTAssertEqual(ids, ModuleID.allCases)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.map(\.rawValue), ["overview", "careScan", "diskMap", "largeOld", "duplicates", "storage",
                                             "aiTools", "worktrees", "modelsDocker", "uninstaller", "startupItems", "history"])
    }

    func testSectionsAreOrderedAndExcludeDisabled() {
        let sections = ModuleRegistry.sections()
        XCTAssertEqual(sections.map(\.0), [.top, .aiWorkspace])   // unbuilt Storage/Apps/Activity modules are hidden
        XCTAssertEqual(sections[0].1.map(\.id), [.overview])
        XCTAssertEqual(sections[1].1.map(\.id), [.aiTools, .worktrees, .modelsDocker])
        XCTAssertTrue(sections.flatMap(\.1).allSatisfy(\.isEnabled))
    }

    func testIncludingDisabledListsEverySectionInOrder() {
        let sections = ModuleRegistry.sections(includeDisabled: true)
        XCTAssertEqual(sections.map(\.0), [.top, .storage, .aiWorkspace, .apps, .activity])
        XCTAssertEqual(sections.flatMap(\.1).map(\.id), ModuleID.allCases)
    }

    func testEveryTitleIsLocalizedInEnglishAndVietnamese() {
        for descriptor in ModuleRegistry.providers.map({ $0.descriptor }) {
            let en = L10n.withLanguage(.en) { descriptor.title }
            let vi = L10n.withLanguage(.vi) { descriptor.title }
            XCTAssertFalse(en.isEmpty, "\(descriptor.id)")
            XCTAssertFalse(vi.isEmpty, "\(descriptor.id)")
            if descriptor.id != .worktrees { XCTAssertNotEqual(en, vi, "\(descriptor.id) has no vi title") }
        }
        for section in ModuleSection.allCases.dropFirst() {
            XCTAssertNotEqual(L10n.withLanguage(.en) { section.title }, L10n.withLanguage(.vi) { section.title })
        }
        XCTAssertNil(ModuleSection.top.title)
    }

    func testSymbolsMatchTheDesignTable() {
        let symbols = Dictionary(uniqueKeysWithValues: ModuleRegistry.providers.map { ($0.descriptor.id, $0.descriptor.symbol) })
        XCTAssertEqual(symbols, [
            .overview: "gauge.with.dots.needle.33percent", .careScan: "sparkles",
            .diskMap: "square.stack.3d.down.right", .largeOld: "doc.badge.clock", .duplicates: "doc.on.doc",
            .storage: "internaldrive", .aiTools: "cpu", .worktrees: "arrow.triangle.branch",
            .modelsDocker: "cube.transparent", .uninstaller: "xmark.app", .startupItems: "power.circle",
            .history: "clock.arrow.circlepath",
        ])
    }

    func testListCategoriesOnlyOnListModules() {
        XCTAssertEqual(ModuleRegistry.descriptor(for: .aiTools).listCategories, [.aiToolData])
        XCTAssertEqual(ModuleRegistry.descriptor(for: .worktrees).listCategories, [.worktree, .buildArtifact])
        XCTAssertEqual(ModuleRegistry.descriptor(for: .modelsDocker).listCategories, [.modelWeights, .docker])
        XCTAssertNil(ModuleRegistry.descriptor(for: .diskMap).listCategories)
    }

    func testSelectionRoundTrip() {
        XCTAssertEqual(SidebarSelection(module: .overview), .overview)
        XCTAssertEqual(SidebarSelection(module: .aiTools), .module(.aiTools))
        XCTAssertEqual(SidebarSelection.overview.moduleID, .overview)
        XCTAssertEqual(SidebarSelection.module(.history).moduleID, .history)
        XCTAssertNil(SidebarSelection.warnings.moduleID)
        XCTAssertNil(SidebarSelection.category(.docker).moduleID)
    }
}
