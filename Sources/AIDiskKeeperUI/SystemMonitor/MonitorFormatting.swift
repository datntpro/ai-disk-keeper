import DiskKeeperCore
import Foundation

/// Percent and rate formatting for the monitor. Decimal separators follow the in-app language.
enum MonitorFormatting {
    static func percent(_ fraction: Double) -> String { "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%" }
    static func percentNumber(_ fraction: Double) -> String { "\(Int((min(max(fraction, 0), 1) * 100).rounded()))" }

    /// "0 KB" instead of the system's spelled-out "Zero kB".
    static var zeroBytes: String { "0 KB" }

    private static func number(_ x: Double, locale: Locale) -> String {
        x.formatted(.number.precision(.fractionLength(x < 10 ? 1 : 0)).locale(locale))
    }

    /// Menu bar form: "1.2M", "24K", "0K". Bits mode multiplies by 8; the letter stays.
    static func compactRate(_ bytesPerSecond: Double, units: NetworkUnits, locale: Locale = L10n.locale) -> String {
        let v = units == .bits ? bytesPerSecond * 8 : bytesPerSecond
        if v < 50 { return "0K" }
        if v >= 1e9 { return number(v / 1e9, locale: locale) + "G" }
        if v >= 1e6 { return number(v / 1e6, locale: locale) + "M" }
        return number(v / 1e3, locale: locale) + "K"
    }

    /// Popover form: "1.2 MB/s" (bytes) or "9.6 Mb/s" (bits).
    static func rate(_ bytesPerSecond: Double, units: NetworkUnits, locale: Locale = L10n.locale) -> String {
        let v = units == .bits ? bytesPerSecond * 8 : bytesPerSecond
        let u = units == .bits ? ["b/s", "Kb/s", "Mb/s", "Gb/s"] : ["B/s", "KB/s", "MB/s", "GB/s"]
        var x = v, i = 0
        while x >= 1000, i < 3 { x /= 1000; i += 1 }
        return (i == 0 ? x.formatted(.number.precision(.fractionLength(0)).locale(locale)) : number(x, locale: locale)) + " " + u[i]
    }

    /// Spoken form: "1.2 megabytes", never "MB/s".
    static func spokenAmount(_ bytesPerSecond: Double, units: NetworkUnits, locale: Locale = L10n.locale) -> String {
        let bits = units == .bits
        let v = bits ? bytesPerSecond * 8 : bytesPerSecond
        let m: Measurement<UnitInformationStorage>
        if bits {
            m = v >= 1e9 ? .init(value: v / 1e9, unit: .gigabits) : v >= 1e6 ? .init(value: v / 1e6, unit: .megabits)
                : v >= 1e3 ? .init(value: v / 1e3, unit: .kilobits) : .init(value: v, unit: .bits)
        } else {
            m = v >= 1e9 ? .init(value: v / 1e9, unit: .gigabytes) : v >= 1e6 ? .init(value: v / 1e6, unit: .megabytes)
                : v >= 1e3 ? .init(value: v / 1e3, unit: .kilobytes) : .init(value: v, unit: .bytes)
        }
        return m.formatted(.measurement(width: .wide, numberFormatStyle: .number.precision(.fractionLength(0...1))).locale(locale))
    }
}
