import Darwin
import Foundation

/// Writes `status.json` atomically: temp file in the same directory (0600 from the start), fsync, rename. Serial
/// (a lock, not an actor) so the quit hook can finish synchronously before the process exits.
public final class HostStatusWriter: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private var last: HostStatus?
    private var stopped = false

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL(environment: PathEnvironment) -> URL {
        URL(fileURLWithPath: environment.applicationSupport + "/AIDiskKeeper/status.json")
    }

    public func write(_ status: HostStatus) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }   // after a clean quit nothing may flip `running` back on
        last = status
        try persist(status)
    }

    /// A clean quit: the last status again, `running: false`, so readers see 3 ("stale") at once instead of a minute later.
    public func markStopped(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        guard var status = last else { return }
        status.running = false
        status.generatedAt = now
        last = status
        try? persist(status)
    }

    /// The setting went off: the file goes away.
    public func remove() {
        lock.lock(); defer { lock.unlock() }
        last = nil
        stopped = false
        unlink(fileURL.path)
    }

    private func persist(_ status: HostStatus) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try HostStatus.makeEncoder().encode(status)
        let tmp = dir.appendingPathComponent("status.json.tmp")
        unlink(tmp.path)
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += n
                }
            }
            fsync(fd)
        } catch {
            close(fd); unlink(tmp.path)
            throw error
        }
        close(fd)
        guard rename(tmp.path, fileURL.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            unlink(tmp.path)
            throw POSIXError(code)
        }
    }
}
