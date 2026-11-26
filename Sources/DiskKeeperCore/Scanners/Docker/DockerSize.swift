import Foundation

enum DockerSize {
    /// The leading token of docker's human size (`"2B (virtual 72.8MB)"` → 2). Decimal `kB/MB/GB/TB` (docker's
    /// `units.HumanSize`), binary `KiB/MiB/GiB/TiB`. `N/A`, empty and negative → nil. The values are rounded, so
    /// callers label them "about".
    static func parse(_ text: String) -> Int64? {
        let token = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard !token.isEmpty, token != "N/A" else { return nil }
        var number = ""
        var unit = ""
        for ch in token {
            if unit.isEmpty, ch.isASCII, ch.isNumber || ch == "." { number.append(ch) } else { unit.append(ch) }
        }
        guard let value = Double(number), value >= 0, value.isFinite else { return nil }
        let multiplier: Double
        switch unit.lowercased() {
        case "b", "": multiplier = 1
        case "kb": multiplier = 1_000
        case "mb": multiplier = 1_000_000
        case "gb": multiplier = 1_000_000_000
        case "tb": multiplier = 1_000_000_000_000
        case "kib": multiplier = 1_024
        case "mib": multiplier = 1_048_576
        case "gib": multiplier = 1_073_741_824
        case "tib": multiplier = 1_099_511_627_776
        default: return nil
        }
        let bytes = value * multiplier
        guard bytes < Double(Int64.max) else { return nil }
        return Int64(bytes.rounded())
    }
}
