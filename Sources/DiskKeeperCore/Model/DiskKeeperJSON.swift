import Foundation

/// Shared JSON configuration for everything we persist (scan cache, audit log, fixtures).
public enum DiskKeeperJSON {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// Sorted keys (+ pretty if requested); ISO-8601 UTC dates with fractional seconds.
    public static func makeEncoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(DiskKeeperJSON.fractional))
        }
        return e
    }

    /// ISO-8601 dates, with or without fractional seconds.
    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = try? DiskKeeperJSON.fractional.parse(s) { return date }
            if let date = try? DiskKeeperJSON.plain.parse(s) { return date }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Invalid ISO-8601 date: \(s)")
        }
        return d
    }
}
