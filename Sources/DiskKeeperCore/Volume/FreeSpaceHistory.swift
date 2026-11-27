import Darwin
import Foundation

/// Free bytes of the Data volume in 10-minute buckets (the smallest value seen in the bucket), 7 days = 1008 points.
public struct FreeSpaceHistory: Sendable, Equatable, Codable {
    public struct Point: Sendable, Equatable, Codable {
        /// Start of the bucket, seconds since 1970.
        public var t: Int
        public var freeBytes: Int64
        public var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }
        public init(t: Int, freeBytes: Int64) { self.t = t; self.freeBytes = freeBytes }
    }

    public static let bucketSeconds = 600
    public static let maxPoints = 1008
    public static let schemaVersion = 1

    public private(set) var points: [Point]

    public init(points: [Point] = []) { self.points = points }

    /// Records a reading. Returns true when it opened a new bucket (the caller persists then, so the file is written
    /// at most every 10 minutes).
    @discardableResult
    public mutating func record(freeBytes: Int64, at date: Date) -> Bool {
        let bucket = Int((date.timeIntervalSince1970 / Double(Self.bucketSeconds)).rounded(.down)) * Self.bucketSeconds
        defer { trim(now: date) }
        if let last = points.last, last.t == bucket {
            points[points.count - 1].freeBytes = min(last.freeBytes, freeBytes)
            return false
        }
        // Out-of-order (clock went back): drop what is newer than this reading rather than keep a bent series.
        while let last = points.last, last.t > bucket { points.removeLast() }
        if let last = points.last, last.t == bucket {
            points[points.count - 1].freeBytes = min(last.freeBytes, freeBytes)
            return false
        }
        points.append(Point(t: bucket, freeBytes: freeBytes))
        return true
    }

    private mutating func trim(now: Date) {
        let cutoff = Int(now.timeIntervalSince1970) - Self.maxPoints * Self.bucketSeconds
        if let first = points.first, first.t < cutoff { points.removeAll { $0.t < cutoff } }
        if points.count > Self.maxPoints { points.removeFirst(points.count - Self.maxPoints) }
    }
}

/// `$APP_SUPPORT/AIDiskKeeper/free-space-history.json`, directory 0700, file 0600, atomic. A corrupt file reads as empty
/// and is replaced by the next save.
public struct FreeSpaceHistoryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL(environment: PathEnvironment) -> URL {
        URL(fileURLWithPath: environment.applicationSupport + "/AIDiskKeeper/free-space-history.json")
    }

    private struct File: Codable { var schemaVersion: Int; var points: [FreeSpaceHistory.Point] }

    public func load() -> FreeSpaceHistory {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data), file.schemaVersion == FreeSpaceHistory.schemaVersion
        else { return FreeSpaceHistory() }
        let sorted = file.points.sorted { $0.t < $1.t }
        return FreeSpaceHistory(points: Array(sorted.suffix(FreeSpaceHistory.maxPoints)))
    }

    public func save(_ history: FreeSpaceHistory) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let data = try JSONEncoder().encode(File(schemaVersion: FreeSpaceHistory.schemaVersion, points: history.points))
        // Created 0600 from the start (no window where it is world-readable), then renamed over the target.
        let tmp = dir.appendingPathComponent(".free-space-history-\(UUID().uuidString).tmp")
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
        } catch {
            close(fd)
            remove(tmp.path)
            throw error
        }
        close(fd)
        guard rename(tmp.path, fileURL.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            remove(tmp.path)
            throw POSIXError(code)
        }
    }
}
