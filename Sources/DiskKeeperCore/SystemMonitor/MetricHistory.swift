import Foundation

/// Fixed-capacity, time-ordered ring buffer of (time, value). In memory only. Older than `maxAge` is trimmed on insert.
/// Time is seconds on any monotonic clock; callers pass the same clock for every insert.
public struct MetricHistory: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public var time: Double
        public var value: Double
        public init(time: Double, value: Double) { self.time = time; self.value = value }
    }
    public static let defaultCapacity = 150
    public static let defaultMaxAge: Double = 300

    public let capacity: Int
    public let maxAge: Double
    private var storage: [Sample] = []
    private var head = 0   // index of the oldest sample once the buffer is full

    public init(capacity: Int = MetricHistory.defaultCapacity, maxAge: Double = MetricHistory.defaultMaxAge) {
        self.capacity = max(1, capacity)
        self.maxAge = maxAge
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int { storage.count }

    /// Oldest first.
    public var samples: [Sample] { Array(storage[head...] + storage[..<head]) }

    public mutating func append(time: Double, value: Double) {
        let s = Sample(time: time, value: value)
        if storage.count < capacity {
            storage.append(s)
        } else {
            storage[head] = s
            head = (head + 1) % capacity
        }
        trim(now: time)
    }

    private mutating func trim(now: Double) {
        let ordered = samples
        guard let first = ordered.first, now - first.time > maxAge else { return }
        let kept = ordered.filter { now - $0.time <= maxAge }
        storage = kept
        head = 0
    }

    /// Samples within the last `window` seconds as of `now`, oldest first.
    public func window(_ window: Double, now: Double) -> [Sample] { samples.filter { now - $0.time <= window } }

    public mutating func removeAll() { storage.removeAll(keepingCapacity: true); head = 0 }
}
