import Foundation

struct StrataSegment: Identifiable, Hashable, Sendable {
    let id: String
    let layer: StrataLayer
    let bytes: Int64
    let label: String
}

/// The pure geometry behind `StrataBar`: cumulative integer offsets (no float drift), small-segment merging,
/// and percentages. A total of 0 gives an empty bar and never a NaN.
struct StrataBarModel: Equatable, Sendable {
    struct Bar: Identifiable, Equatable, Sendable {
        let segment: StrataSegment
        let start: Int64
        let end: Int64
        var id: String { segment.id }
    }

    static let mergeThreshold = 0.005

    let bars: [Bar]
    let total: Int64
    let free: Int64

    init(segments: [StrataSegment], total: Int64, free: Int64? = nil) {
        let total = max(total, 0)
        self.total = total
        guard total > 0 else { bars = []; self.free = 0; return }
        var kept: [StrataSegment] = []
        var mergedBytes: Int64 = 0
        for s in segments where s.bytes > 0 {
            if Double(s.bytes) / Double(total) < Self.mergeThreshold {
                mergedBytes += s.bytes
            } else {
                kept.append(s)
            }
        }
        if mergedBytes > 0 {
            kept.append(StrataSegment(id: "strata.other", layer: .other, bytes: mergedBytes, label: loc("strata.other", "Other")))
        }
        var running: Int64 = 0
        var out: [Bar] = []
        for s in kept {
            let end = min(running + s.bytes, total)
            if end > running { out.append(Bar(segment: s, start: running, end: end)) }
            running = end
        }
        bars = out
        self.free = min(max(free ?? 0, 0), total - running)
    }

    func fraction(_ bytes: Int64) -> Double { total > 0 ? Double(bytes) / Double(total) : 0 }

    /// Percent, rounded to a whole number, for accessibility text.
    func percent(_ bytes: Int64) -> Int { Int((fraction(bytes) * 100).rounded()) }
}
