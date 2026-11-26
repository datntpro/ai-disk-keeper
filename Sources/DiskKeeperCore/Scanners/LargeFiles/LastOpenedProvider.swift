import CoreServices
import Darwin
import Foundation

/// Every date we can learn about a file without reading it.
public struct FileDates: Sendable, Hashable {
    public var spotlightLastUsed: Date?
    public var accessed: Date?
    public var modified: Date
    public var created: Date

    public init(spotlightLastUsed: Date? = nil, accessed: Date? = nil, modified: Date, created: Date) {
        self.spotlightLastUsed = spotlightLastUsed
        self.accessed = accessed
        self.modified = modified
        self.created = created
    }
}

public enum LastOpenedSource: String, Codable, Sendable, Hashable { case spotlight, accessed, modified }

extension FileDates {
    /// The most recent of the three signals, and which one it was. Deliberately conservative: a file counts
    /// as old only when every signal says so. Ties prefer Spotlight, then access, then modification.
    public var lastOpened: (date: Date, source: LastOpenedSource) {
        var best: (Date, LastOpenedSource) = (modified, .modified)
        if let accessed, accessed > best.0 { best = (accessed, .accessed) }
        if let spotlightLastUsed, spotlightLastUsed >= best.0 { best = (spotlightLastUsed, .spotlight) }
        return best
    }
}

public protocol LastOpenedProviding: Sendable {
    /// `nil` when the file can't be inspected (gone, not readable).
    func dates(for path: String) -> FileDates?
}

/// `kMDItemLastUsedDate` from Spotlight (metadata only, no content read) plus the file's atime.
public struct SpotlightLastOpenedProvider: LastOpenedProviding {
    public init() {}

    public func dates(for path: String) -> FileDates? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        func date(_ t: timespec) -> Date { Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_nsec) / 1e9) }
        var used: Date?
        if let item = MDItemCreate(nil, path as CFString),
           let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            used = value
        }
        return FileDates(spotlightLastUsed: used, accessed: date(st.st_atimespec),
                         modified: date(st.st_mtimespec), created: date(st.st_birthtimespec))
    }
}
