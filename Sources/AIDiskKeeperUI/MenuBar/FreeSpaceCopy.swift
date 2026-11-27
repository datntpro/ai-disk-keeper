import Foundation

/// Strings of the free-space warning and trend (prefix `freespace.`). Numbers arrive already formatted.
enum FreeSpaceCopy {
    static var stable: String { loc("freespace.stable", "Free space is stable") }
    static func fullIn(_ duration: String) -> String { loc("freespace.fullIn", "Full in about \(duration) at the current rate") }
    static func lowA11y(_ percent: String) -> String { loc("freespace.low.a11y", "Low disk space: \(percent) free") }
    static func criticalA11y(_ percent: String) -> String { loc("freespace.critical.a11y", "Critically low disk space: \(percent) free") }

    /// "2 days", "5 hours": one unit, rounded, in the app's language.
    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 86_400 ? [.day] : seconds >= 3600 ? [.hour] : [.minute]
        f.maximumUnitCount = 1
        f.unitsStyle = .full
        var calendar = Calendar.current
        calendar.locale = L10n.locale
        f.calendar = calendar
        return f.string(from: max(60, seconds)) ?? ""
    }
}
