import DiskKeeperCore
import Foundation

enum ItemFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    static func item(_ name: String, tool: ToolID = .claudeCode, category: ItemCategory = .aiToolData,
                     tier: RiskTier = .safe, size: Int64 = 1000, lastModified: Date? = nil,
                     cleanup: CleanupMethod = .trash, ruleID: String = "rule.fixture") -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: "/tmp/fixture/\(tool.rawValue)/\(name)"), displayName: name,
                 tool: tool, category: category, sizeAllocated: size, sizeLogical: size, fileCount: 1,
                 lastModified: lastModified, tier: tier, explanation: "Because \(name)", ruleID: ruleID,
                 cleanupMethod: cleanup)
    }

    static func result(_ items: [ScanItem], cancelled: Bool = false, warnings: [ScanWarning] = []) -> ScanResult {
        ScanResult(items: items, warnings: warnings, startedAt: t0, finishedAt: t0.addingTimeInterval(1),
                   wasCancelled: cancelled)
    }

    static func progress(found: Int = 0, bytes: Int64 = 0) -> ScanProgress {
        ScanProgress(itemsFound: found, bytesFound: bytes)
    }
}
