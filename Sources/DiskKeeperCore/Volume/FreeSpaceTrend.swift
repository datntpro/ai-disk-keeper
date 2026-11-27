import Foundation

public enum FreeSpaceLevel: String, Sendable, Equatable, Codable { case ok, warning, critical }

/// Where free space is heading.
public enum FreeSpaceTrend {
    public struct Trend: Sendable, Equatable {
        /// Negative = shrinking.
        public let bytesPerHour: Double
        /// nil = "stable": not shrinking, or more than 30 days away (hidden).
        public let timeToFull: TimeInterval?
        public let r2: Double
    }

    public static let minimumSpan: TimeInterval = 6 * 3600
    public static let minimumR2 = 0.5
    public static let maximumHorizon: TimeInterval = 30 * 86_400
    /// An upward step bigger than this is a cleanup: the window restarts after it.
    public static let cleanupJump: Int64 = 1_000_000_000

    /// nil = not enough history (< 6 h after the last cleanup) or a shrinking but noisy fit (r² < 0.5).
    public static func estimate(_ all: [FreeSpaceHistory.Point], now: Date) -> Trend? {
        var window = all.sorted { $0.t < $1.t }
        if let jump = window.indices.dropFirst().last(where: { window[$0].freeBytes - window[$0 - 1].freeBytes > cleanupJump }) {
            window = Array(window[jump...])
        }
        guard window.count >= 3, let first = window.first, let last = window.last,
              TimeInterval(last.t - first.t) >= minimumSpan else { return nil }
        let n = Double(window.count)
        let xs = window.map { Double($0.t - first.t) }   // seconds
        let ys = window.map { Double($0.freeBytes) }
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for (x, y) in zip(xs, ys) { sxx += (x - mx) * (x - mx); sxy += (x - mx) * (y - my); syy += (y - my) * (y - my) }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx   // bytes per second
        let perHour = slope * 3600
        if slope >= 0 { return Trend(bytesPerHour: perHour, timeToFull: nil, r2: 1) }
        let r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 0
        guard r2 >= minimumR2 else { return nil }
        let eta = Double(last.freeBytes) / -slope
        return Trend(bytesPerHour: perHour, timeToFull: eta > maximumHorizon ? nil : max(0, eta), r2: r2)
    }
}

public struct FreeSpaceStatus: Sendable, Equatable {
    public let freeBytes: Int64, totalBytes: Int64
    public let freeFraction: Double
    public let level: FreeSpaceLevel
    public let trend: FreeSpaceTrend.Trend?

    public static let criticalFraction = 0.05
    public static let criticalBytes: Int64 = 10_000_000_000

    public init(freeBytes: Int64, totalBytes: Int64, thresholdPercent: Int, trend: FreeSpaceTrend.Trend?) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        let fraction = totalBytes > 0 ? min(1, max(0, Double(freeBytes) / Double(totalBytes))) : 0
        self.freeFraction = fraction
        self.trend = trend
        if totalBytes > 0, fraction < Self.criticalFraction || freeBytes < Self.criticalBytes { level = .critical }
        else if totalBytes > 0, fraction < Double(thresholdPercent) / 100 { level = .warning }
        else { level = .ok }
    }
}
