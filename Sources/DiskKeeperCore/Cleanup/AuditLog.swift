import Darwin
import Foundation

public struct AuditRecord: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let timestamp: Date
    public let runID: UUID
    public let itemID: String
    public let path: String
    public let bytes: Int64
    public let action: CleanupAction
    /// "trashed" | "deleted" | "skipped" | "failed"
    public let result: String
    public let trashPath: String?
    public let ruleID: String
    public let tool: ToolID
    /// Blocker codes for skipped items.
    public let reasons: [String]
    public let error: String?

    public init(schemaVersion: Int = 1, timestamp: Date, runID: UUID, itemID: String, path: String,
                bytes: Int64, action: CleanupAction, result: String, trashPath: String?, ruleID: String,
                tool: ToolID, reasons: [String], error: String?) {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.runID = runID
        self.itemID = itemID
        self.path = path
        self.bytes = bytes
        self.action = action
        self.result = result
        self.trashPath = trashPath
        self.ruleID = ruleID
        self.tool = tool
        self.reasons = reasons
        self.error = error
    }
}

public enum AuditLogError: Error, Equatable {
    case notOpen
    case unsafePath(String)
    case posix(String, Int32)
    case injectedFailure
}

/// Append-only JSON Lines audit log. One record per line, fsynced after each append.
public actor AuditLog {
    private let fileURL: URL
    private var fd: Int32 = -1
    private var failAfter: Int?
    private var appended = 0

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// `$APP_SUPPORT/AIDiskKeeper/audit.jsonl`.
    public static func defaultURL(environment: PathEnvironment) -> URL {
        URL(fileURLWithPath: environment.applicationSupport + "/AIDiskKeeper/audit.jsonl")
    }

    /// TEST-ONLY: make every append after the first `n` throw.
    func _failAfter(_ n: Int) { failAfter = n; appended = 0 }

    func open() throws {
        if fd >= 0 { return }
        let parent = fileURL.deletingLastPathComponent().path
        var st = stat()
        if lstat(parent, &st) != 0 {
            guard errno == ENOENT else { throw AuditLogError.posix("lstat \(parent)", errno) }
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: parent), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard lstat(parent, &st) == 0 else { throw AuditLogError.posix("lstat \(parent)", errno) }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw AuditLogError.unsafePath(parent) }
        let handle = Darwin.open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard handle >= 0 else { throw AuditLogError.posix("open \(fileURL.path)", errno) }
        fd = handle
    }

    func append(_ record: AuditRecord) throws {
        guard fd >= 0 else { throw AuditLogError.notOpen }
        if let failAfter, appended >= failAfter { throw AuditLogError.injectedFailure }
        var line = try DiskKeeperJSON.makeEncoder().encode(record)
        line.append(0x0A)
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AuditLogError.posix("write", errno)
                }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw AuditLogError.posix("fsync", errno) }
        appended += 1
    }

    func close() {
        if fd >= 0 { _ = Darwin.close(fd) }
        fd = -1
    }

    /// Reads all records, skipping malformed lines.
    public static func read(_ fileURL: URL) throws -> [AuditRecord] {
        let data = try Data(contentsOf: fileURL)
        let decoder = DiskKeeperJSON.makeDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(AuditRecord.self, from: Data($0)) }
    }
}
