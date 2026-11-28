import AppKit
import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class BuildCachesModuleTests: XCTestCase {
    private func item(_ name: String, rule: String, size: Int64, tool: ToolID = "build-caches") -> ScanItem {
        ItemFixtures.item(name, tool: tool, category: .systemJunk, size: size, ruleID: rule)
    }

    func testModuleListsOnlyBuildCacheRulesInsideSystemJunk() {
        let items = [
            item("dd", rule: "build-caches.xcode-deriveddata", size: 10),
            item("go", rule: "dev-caches.go-build", size: 20, tool: "dev-caches"),
            item("npm", rule: "system.npm-cache", size: 30, tool: "system"),
            item("tmp", rule: "system.agent-temp", size: 40, tool: "system"),
            item("logs", rule: "system.ai-logs.claude", size: 50, tool: "system"),
            ItemFixtures.item("wt", category: .worktree, ruleID: "dev-caches.go-build"),
        ]
        let query = ItemQuery(scope: .module(.buildCaches))
        XCTAssertEqual(query.apply(to: items).map(\.displayName).sorted(), ["dd", "go", "npm"])
        XCTAssertEqual(BuildCachesModule.descriptor.section, .aiWorkspace)
        XCTAssertTrue(BuildCachesModule.descriptor.isEnabled)
    }

    func testSummaryGroupsByFamilyAndCollectsHints() {
        let items = [
            item("dd1", rule: "build-caches.xcode-deriveddata", size: 10),
            item("dd2", rule: "build-caches.xcode-deriveddata", size: 5),
            item("pnpm", rule: "build-caches.pnpm-store", size: 100),
            item("oci", rule: "build-caches.tart-oci", size: 1000),
            item("vm", rule: "build-caches.tart-vms", size: 2000),
            item("unrelated", rule: "system.agent-temp", size: 7, tool: "system"),
        ]
        let s = BuildCachesSummary(items: items)
        XCTAssertEqual(s.groups.map(\.family), [.xcode, .javascript, .vms])
        XCTAssertEqual(s.groups.first, .init(family: .xcode, itemCount: 2, bytes: 15))
        XCTAssertEqual(s.hints.map(\.command), ["pnpm store prune", "tart prune --entries=caches --older-than=7", "tart delete <name>"])
        XCTAssertTrue(BuildCachesSummary(items: []).groups.isEmpty)
    }

    func testCopyButtonCopiesTheExactCommand() {
        let pb = NSPasteboard(name: NSPasteboard.Name("adk.h7.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        for hint in BuildCacheCatalog.hints where hint.copyable {
            CleanupHintCard.copy(hint.command, to: pb)
            XCTAssertEqual(pb.string(forType: .string), hint.command)
        }
    }

    func testTheDestructiveDeleteHintHasNoCopyButton() {
        let hint = BuildCacheCatalog.hints.first { $0.command.hasPrefix("tart delete") }
        XCTAssertEqual(hint?.copyable, false)
        XCTAssertTrue(BuildCacheCatalog.hints.filter { !$0.copyable }.count == 1)
    }

    func testTartTmpExplanationsTranslate() {
        for v in TartTmpVariant.allCases {
            let en = L10n.withLanguage(.en) { BuildCachesTexts.explanation(v) }
            XCTAssertEqual(en, v.explanation)
            XCTAssertNotEqual(en, L10n.withLanguage(.vi) { BuildCachesTexts.explanation(v) })
        }
    }

    func testDerivedDataExplanationsTranslate() {
        for v in DerivedDataVariant.allCases {
            let en = L10n.withLanguage(.en) { BuildCachesTexts.explanation(v) }
            let vi = L10n.withLanguage(.vi) { BuildCachesTexts.explanation(v) }
            XCTAssertEqual(en, v.explanation, "the English copy must equal the scanner's explanation")
            XCTAssertNotEqual(en, vi)
        }
    }
}
