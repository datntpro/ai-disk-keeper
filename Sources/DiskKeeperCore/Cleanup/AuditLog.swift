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
    /// "trashed" | "deleted" | "ran" | "skipped" | "failed" | "intent" (written before a destructive tool command;
    /// an intent with no later outcome line means the app or the tool died in between).
    public let result: String
    public static let intentResult = "intent"
    public let trashPath: String?
    public let ruleID: String
    public let tool: ToolID
    /// Blocker codes for skipped items.
    public let reasons: [String]
    public let error: String?
    /// Set for every `.trashApplication` entry. Additive: schemaVersion stays 1, old lines decode without it.
    public let bundleID: String?
    /// Tool commands only (additive, like `bundleID`): the absolute executable followed by the exact argv.
    public let command: [String]?
    public let exitStatus: Int32?
    public let durationMs: Int?
    /// At most 2 KB, UTF-8 safe.
    public let stderrTail: String?
    /// For example the container runtime the command ran against.
    public let toolTarget: String?
    /// Pairs an `intent` line with the outcome line of the same command run (additive; nil on old lines).
    public let intentID: UUID?

    public init(schemaVersion: Int = 1, timestamp: Date, runID: UUID, itemID: String, path: String,
                bytes: Int64, action: CleanupAction, result: String, trashPath: String?, ruleID: String,
                tool: ToolID, reasons: [String], error: String?, bundleID: String? = nil,
                command: [String]? = nil, exitStatus: Int32? = nil, durationMs: Int? = nil,
                stderrTail: String? = nil, toolTarget: String? = nil, intentID: UUID? = nil) {
        self.intentID = intentID
        self.command = command
        self.exitStatus = exitStatus
        self.durationMs = durationMs
        self.stderrTail = stderrTail
        self.toolTarget = toolTarget
        self.bundleID = bundleID
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

/// One line of `audit.jsonl` written when the Uninstaller asks a running app to quit (or force quits it).
/// Distinguished from `AuditRecord` lines by `kind == "appQuit"`; `AuditLog.read` skips these by design.
public struct AppQuitAuditRecord: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let kind: String
    public let timestamp: Date
    /// One Quit press = one flow.
    public let flowID: UUID
    public let bundleID: String
    public let appPath: String
    /// "graceful" | "force"
    public let mode: String
    /// "requested" | "result"
    public let phase: String
    /// "quit" | "stillRunning" | "refused"; nil for `requested`.
    public let result: String?
    public let pids: [Int32]
    public let instanceCount: Int
    /// `AppQuitRefusal` raw values, if any.
    public let reasons: [String]
    public let error: String?

    public init(schemaVersion: Int = 1, timestamp: Date, flowID: UUID, bundleID: String, appPath: String, mode: String,
                phase: String, result: String?, pids: [Int32], instanceCount: Int, reasons: [String] = [], error: String? = nil) {
        self.schemaVersion = schemaVersion
        self.kind = "appQuit"
        self.timestamp = timestamp
        self.flowID = flowID
        self.bundleID = bundleID
        self.appPath = appPath
        self.mode = mode
        self.phase = phase
        self.result = result
        self.pids = pids
        self.instanceCount = instanceCount
        self.reasons = reasons
        self.error = error
    }
}

/// One line of `audit.jsonl` per process touched by process control (H5). `kind == "processControl"`; `AuditLog.read`
/// skips these by design. Never counted in byte totals.
public struct ProcessControlAuditRecord: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let kind: String
    public let timestamp: Date
    /// One confirmed action = one flow; History groups the lines by it.
    public let flowID: UUID
    /// `ProcessAction` raw value.
    public let action: String
    public let pid: Int32
    public let name: String
    /// Name of the process the user picked, when this line is one of its descendants.
    public let root: String?
    /// "done" | "failed" | "refused:<code>"
    public let result: String
    public let errno: Int32?

    public init(schemaVersion: Int = 1, timestamp: Date, flowID: UUID, action: String, pid: Int32, name: String,
                root: String?, result: String, errno: Int32?) {
        self.schemaVersion = schemaVersion
        self.kind = "processControl"
        self.timestamp = timestamp; self.flowID = flowID; self.action = action; self.pid = pid; self.name = name
        self.root = root; self.result = result; self.errno = errno
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
    /// Open/close are reference-counted so one holder cannot close the file under another.
    private var openCount = 0
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
        if fd >= 0 { openCount += 1; return }
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
        openCount = 1
    }

    func append(_ record: AuditRecord) throws { try appendLine(record) }

    /// Opens (ref-counted), appends one line, fsyncs, closes.
    func appendStandalone(_ record: AuditRecord) throws {
        try open()
        defer { close() }
        try appendLine(record)
    }

    /// Opens (ref-counted), appends one quit line, fsyncs, closes. Throws like `open()` / `append`.
    public func appendQuitEvent(_ record: AppQuitAuditRecord) throws {
        try open()
        defer { close() }
        try appendLine(record)
    }

    /// Opens (ref-counted), appends one process-control line, fsyncs, closes.
    public func appendProcessControlEvent(_ record: ProcessControlAuditRecord) throws {
        try open()
        defer { close() }
        try appendLine(record)
    }

    private func appendLine<T: Encodable>(_ record: T) throws {
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
        openCount = max(0, openCount - 1)
        guard openCount == 0 else { return }
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
