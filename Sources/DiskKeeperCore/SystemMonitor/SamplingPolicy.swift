import Foundation

/// What is asking for numbers right now.
public struct Demand: Sendable, Equatable {
    public var popoverOpen = false
    /// Metrics drawn in the menu bar (disk is handled by the always-on volume poll).
    public var barMetrics: Set<MetricID> = []
    public var enabledMetrics: Set<MetricID> = Set(MetricID.allCases)
    public var topProcessesVisible = false
    public var itemInserted = true
    public var displayAsleep = false
    public var systemAsleep = false
    public var barInterval: Duration = .seconds(5)
    public init() {}
}

/// What the scheduler must sample.
public struct SamplePlan: Sendable, Equatable {
    /// CPU / memory / network cadence; nil = none.
    public var metricsInterval: Duration?
    public var metrics: Set<MetricID>
    public var perCore: Bool
    public var topProcesses: Bool
    /// The volume poll (low-space alert); nil only while the Mac sleeps.
    public var diskInterval: Duration?
}

public enum SamplingPolicy {
    public static let popoverInterval: Duration = .seconds(2)
    public static let diskInterval: Duration = .seconds(60)
    public static let barIntervalChoices = [2, 5, 10, 30]

    public static func snapBarSeconds(_ s: Int) -> Int {
        barIntervalChoices.min { abs($0 - s) < abs($1 - s) } ?? 5
    }

    public static func plan(_ d: Demand) -> SamplePlan {
        let none = SamplePlan(metricsInterval: nil, metrics: [], perCore: false, topProcesses: false, diskInterval: diskInterval)
        if d.systemAsleep { return SamplePlan(metricsInterval: nil, metrics: [], perCore: false, topProcesses: false, diskInterval: nil) }
        if !d.itemInserted || d.displayAsleep { return none }
        let live: Set<MetricID> = [.cpu, .memory, .network]
        if d.popoverOpen {
            let metrics = d.enabledMetrics.intersection(live)
            return SamplePlan(metricsInterval: metrics.isEmpty ? nil : popoverInterval, metrics: metrics,
                              perCore: metrics.contains(.cpu), topProcesses: d.topProcessesVisible,
                              diskInterval: diskInterval)
        }
        let bar = d.barMetrics.intersection(d.enabledMetrics).intersection(live)
        guard !bar.isEmpty else { return none }
        return SamplePlan(metricsInterval: d.barInterval, metrics: bar, perCore: false, topProcesses: false, diskInterval: diskInterval)
    }
}
