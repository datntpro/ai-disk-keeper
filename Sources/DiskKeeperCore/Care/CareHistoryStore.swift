import Darwin
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

    /// Missing or corrupt file → `[]`. Never throws. Entries of a newer schema are returned too (and kept when
    /// appending); callers that compare totals use only `schemaVersion == 1`.
    public func load() -> [CareSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let all = try? DiskKeeperJSON.makeDecoder().decode([CareSnapshot].self, from: data) else { return [] }
        return all
    }

    /// Appends, keeps the newest 20, writes atomically (directory 0700, file 0600). A corrupt file is replaced.
    public func append(_ snapshot: CareSnapshot) throws {
        let kept = Array((load() + [snapshot]).suffix(Self.retention))
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let data = try DiskKeeperJSON.makeEncoder(pretty: true).encode(kept)
        // Create the temp file 0600 from the start (no window where it is world-readable), then rename over the target.
        let tmp = dir.appendingPathComponent(".care-history-\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += n
                }
            }
            fsync(fd)
            close(fd)
            guard rename(tmp.path, fileURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            close(fd)
            remove(tmp.path)   // our own half-written temp file
            throw error
        }
    }
}
