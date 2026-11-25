import Foundation
@testable import DiskKeeperCore

enum ModelFixtures {
    static let date = Date(timeIntervalSince1970: 1_793_000_000)

    static func item(path: String = "/Users/test/a",
                     tier: RiskTier = .safe,
                     tool: ToolID = .claudeCode,
                     category: ItemCategory = .aiToolData,
                     project: ProjectRef? = nil,
                     allocated: Int64 = 100,
                     logical: Int64 = 90,
                     files: Int = 1,
                     cleanup: CleanupMethod = .trash,
                     ruleID: String = "r") -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: path), displayName: "n", tool: tool, category: category,
                 project: project, sizeAllocated: allocated, sizeLogical: logical, fileCount: files,
                 lastModified: date, tier: tier, explanation: "e", ruleID: ruleID,
                 cleanupMethod: cleanup)
    }

    static func fullItem() -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: "/Users/test/Library/Application Support/Cursor 🚀/cache"),
                 displayName: "Cursor 🚀", tool: .cursor, category: .docker,
                 project: ProjectRef(id: "/Users/test/app", displayName: "app"),
                 sizeAllocated: 34_000_000_000, sizeLogical: 36_000_000_000, fileCount: 12,
                 lastModified: date, tier: .review, explanation: "Because.", ruleID: "cursor.cache",
                 cleanupMethod: .toolCommand(command: "docker", arguments: ["system", "prune"]),
                 requiresAppQuit: "com.example.app", flags: Set(ItemFlag.allCases))
    }
}

func roundTrip<T: Codable>(_ value: T) throws -> T {
    try DiskKeeperJSON.makeDecoder().decode(T.self, from: DiskKeeperJSON.makeEncoder().encode(value))
}

func jsonString<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try DiskKeeperJSON.makeEncoder().encode(value), as: UTF8.self)
}

func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try DiskKeeperJSON.makeDecoder().decode(type, from: Data(json.utf8))
}
