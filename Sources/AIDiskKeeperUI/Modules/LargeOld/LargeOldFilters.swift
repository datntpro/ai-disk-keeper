import DiskKeeperCore
import Foundation

enum SizeThreshold: String, CaseIterable, Hashable, Sendable {
    case mb100, mb250, mb500, gb1, gb5

    var bytes: Int64 {
        switch self {
        case .mb100: 100_000_000
        case .mb250: 250_000_000
        case .mb500: 500_000_000
        case .gb1: 1_000_000_000
        case .gb5: 5_000_000_000
        }
    }
}

enum AgeThreshold: String, CaseIterable, Hashable, Sendable {
    case any, m1, m3, m6, y1, y2

    var months: Int {
        switch self {
        case .any: 0
        case .m1: 1
        case .m3: 3
        case .m6: 6
        case .y1: 12
        case .y2: 24
        }
    }
}

/// What the user narrowed the list to. Pure and synchronous; the model re-applies it on every change.
struct LargeOldFilters: Hashable {
    var minBytes: SizeThreshold = .mb500
    var age: AgeThreshold = .m6
    /// Absolute folder path; `nil` = the whole scope (Home).
    var folder: String?
    /// Empty = every kind.
    var kinds: Set<LargeFileKind> = []
    var search = ""

    func apply(_ files: [LargeFile], now: Date, calendar: Calendar = .current) -> [LargeFile] {
        kindFree(files, now: now, calendar: calendar).filter { kinds.isEmpty || kinds.contains($0.kind) }
    }

    /// Everything except the kind filter: the summary cards count over this, so a card keeps its number while on.
    func kindFree(_ files: [LargeFile], now: Date, calendar: Calendar = .current) -> [LargeFile] {
        let cutoff = age == .any ? nil : calendar.date(byAdding: .month, value: -age.months, to: now)
        let folderPrefix = folder.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let needle = search.trimmingCharacters(in: .whitespaces)
        return files.filter { f in
            guard f.allocatedBytes >= minBytes.bytes else { return false }
            if let cutoff, f.lastOpened > cutoff { return false }
            if let folderPrefix, !f.path.hasPrefix(folderPrefix) { return false }
            if !needle.isEmpty, f.path.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
            return true
        }
    }
}
