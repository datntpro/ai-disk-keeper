import Foundation

/// Totals of one completed Care Scan. No paths and no item lists (privacy): only bytes per tool and per module.
public struct CareSnapshot: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let finishedAt: Date
    /// Hash of disabled tools + index scope (+ project roots); passed in by the UI. Growth only compares equal fingerprints.
    public let scopeFingerprint: String
    /// ToolID raw → allocated bytes of aiToolData items, all tiers.
    public let perTool: [String: Int64]
    /// CareModule raw → total bytes.
    public let perModule: [String: Int64]

    public init(finishedAt: Date, scopeFingerprint: String, perTool: [String: Int64], perModule: [String: Int64]) {
        self.schemaVersion = 1
        self.finishedAt = finishedAt
        self.scopeFingerprint = scopeFingerprint
        self.perTool = perTool
        self.perModule = perModule
    }
}

/// The last ``retention`` snapshots as JSON (default: Application Support/AIDiskKeeper/care-history.json).
/// Writing this file is the only write a Care Scan makes.
public struct CareHistoryStore: Sendable {
    public static let retention = 20
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL(environment: PathEnvironment) -> URL {
        URL(fileURLWithPath: environment.applicationSupport + "/AIDiskKeeper/care-history.json")
    }

    /// Missing or corrupt file → `[]`. Never throws.
    public func load() -> [CareSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let all = try? DiskKeeperJSON.makeDecoder().decode([CareSnapshot].self, from: data) else { return [] }
        return all.filter { $0.schemaVersion == 1 }
    }

    /// Appends, keeps the newest 20, writes atomically (directory 0700, file 0600). A corrupt file is replaced.
    public func append(_ snapshot: CareSnapshot) throws {
        let kept = Array((load() + [snapshot]).suffix(Self.retention))
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try DiskKeeperJSON.makeEncoder(pretty: true).encode(kept)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
