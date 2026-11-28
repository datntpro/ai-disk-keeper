import Darwin
import Foundation

/// A process this app stopped with SIGSTOP. Persisted so a crash or a kill -9 of the app can be recovered at launch.
public struct PausedProcess: Codable, Sendable, Hashable {
    public let pid: pid_t
    public let startID: UInt64
    public let name: String
    public let pausedAt: Date
    public var resumeAt: Date

    public init(pid: pid_t, startID: UInt64, name: String, pausedAt: Date, resumeAt: Date) {
        self.pid = pid; self.startID = startID; self.name = name; self.pausedAt = pausedAt; self.resumeAt = resumeAt
    }
    public var key: ProcessKey { ProcessKey(pid: pid, startID: startID) }
}

/// `$APP_SUPPORT/AIDiskKeeper/paused.json`, mode 0600, written atomically. Holds only what is paused right now:
/// an empty list removes the file. Unreadable or damaged content reads as empty (nothing is ever guessed).
public struct PausedProcessStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultURL(environment: PathEnvironment) -> URL {
        URL(fileURLWithPath: environment.applicationSupport + "/AIDiskKeeper/paused.json")
    }

    private struct File: Codable { var schemaVersion = 1; var paused: [PausedProcess] }

    public func load() -> [PausedProcess] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? DiskKeeperJSON.makeDecoder().decode(File.self, from: data), file.schemaVersion == 1 else { return [] }
        return file.paused
    }

    public func save(_ entries: [PausedProcess]) throws {
        if entries.isEmpty {
            do { try FileManager.default.removeItem(at: fileURL) } catch let e as CocoaError where e.code == .fileNoSuchFile {}
            return
        }
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try DiskKeeperJSON.makeEncoder().encode(File(paused: entries))
        // Created 0600 from the start (never world-readable, not even briefly), then renamed over the target: a symlink
        // sitting at `fileURL` is replaced, never written through.
        let tmp = dir.appendingPathComponent(".paused-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(tmp.path, fileURL.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
