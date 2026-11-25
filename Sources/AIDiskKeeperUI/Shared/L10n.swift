import Foundation

/// Single entry point for user-facing strings: a stable key plus the English default.
/// A String Catalog (T49) adds translations by key; `bundle` is the one place to point at it.
enum L10n {
    static let bundle: Bundle = .main

    static func finishedAnnouncement(bytes: String, count: Int) -> String {
        tr("status.finished", "Scan finished: \(bytes) in \(count) items")
    }

    static func tr(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: bundle)
    }
}
