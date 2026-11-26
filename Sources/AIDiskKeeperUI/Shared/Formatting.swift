import Foundation

/// Number, byte and date formatting for the UI. Every function takes the locale explicitly (default: the in-app
/// language's locale), so vi shows `1,23 GB` / `1.234` and en shows `1.23 GB` / `1,234` whatever the system region.
public enum Formatting {
    public static func bytes(_ n: Int64, locale: Locale = L10n.locale) -> String {
        n.formatted(.byteCount(style: .file).locale(locale))
    }

    public static func count(_ n: Int, locale: Locale = L10n.locale) -> String {
        n.formatted(.number.locale(locale))
    }

    public static func relative(_ date: Date?, now: Date = Date(), locale: Locale = L10n.locale) -> String {
        guard let date else { return "—" }
        if abs(now.timeIntervalSince(date)) < 60 { return loc("time.justNow", "just now") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = locale
        return f.localizedString(for: date, relativeTo: now)
    }

    public static func absolute(_ date: Date?, locale: Locale = L10n.locale) -> String {
        guard let date else { return "—" }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
}
