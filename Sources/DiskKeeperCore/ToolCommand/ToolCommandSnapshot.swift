import Darwin
import Foundation

/// `dev, ino, size, mtime` of the resolved executable; any difference between plan and run refuses the command.
public struct ExecutableIdentity: Codable, Sendable, Hashable {
    public let dev: Int64
    public let ino: UInt64
    public let size: Int64
    public let mtimeSeconds: Int64
    public let mtimeNanoseconds: Int64
    /// Status-change time: unlike mtime it can't be restored after an in-place rewrite.
    public let ctimeSeconds: Int64
    public let ctimeNanoseconds: Int64

    public init(dev: Int64, ino: UInt64, size: Int64, mtimeSeconds: Int64, mtimeNanoseconds: Int64,
                ctimeSeconds: Int64 = 0, ctimeNanoseconds: Int64 = 0) {
        self.ctimeSeconds = ctimeSeconds; self.ctimeNanoseconds = ctimeNanoseconds
        self.dev = dev; self.ino = ino; self.size = size
        self.mtimeSeconds = mtimeSeconds; self.mtimeNanoseconds = mtimeNanoseconds
    }

    /// nil when the file can't be stat'ed.
    public static func of(path: String) -> ExecutableIdentity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return ExecutableIdentity(dev: Int64(st.st_dev), ino: UInt64(st.st_ino), size: Int64(st.st_size),
                                  mtimeSeconds: Int64(st.st_mtimespec.tv_sec), mtimeNanoseconds: Int64(st.st_mtimespec.tv_nsec),
                                  ctimeSeconds: Int64(st.st_ctimespec.tv_sec), ctimeNanoseconds: Int64(st.st_ctimespec.tv_nsec))
    }
}

/// What the dry run showed: the executable, the exact argv and the environment. Part of the plan entry, so an
/// edit is `planModified`, and compared again right before the command runs.
public struct ToolCommandSnapshot: Codable, Sendable, Hashable {
    public let specID: String
    public let executablePath: String
    public let argv: [String]
    public let environmentDisplay: [String: String]
    /// For example "orbstack" or a simulator runtime; nil when the target has no name.
    public let targetLabel: String?
    /// Identity of the resolved executable at plan time; nil only for snapshots built without one.
    public let executableIdentity: ExecutableIdentity?

    public init(specID: String, executablePath: String, argv: [String], environmentDisplay: [String: String],
                targetLabel: String?, executableIdentity: ExecutableIdentity? = nil) {
        self.executableIdentity = executableIdentity
        self.specID = specID
        self.executablePath = executablePath
        self.argv = argv
        self.environmentDisplay = environmentDisplay
        self.targetLabel = targetLabel
    }

    /// Absolute executable followed by the argv, exactly as it is spawned.
    public var command: [String] { [executablePath] + argv }
}
