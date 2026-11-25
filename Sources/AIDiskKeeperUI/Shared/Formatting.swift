import Foundation

public enum Formatting {
    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    public static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    public static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        if abs(now.timeIntervalSince(date)) < 60 { return loc("time.justNow", "just now") }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    public static func absolute(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
