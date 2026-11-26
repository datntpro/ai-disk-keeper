import Foundation

/// Decides when the low-space alert fires: once per crossing. It fires on the step from "at or above the threshold"
/// to "below it", then stays quiet until free space has risen above `threshold + hysteresis` (so it can't flap).
/// Pure value; `armed` is persisted so a relaunch while still low does not alert again.
struct LowSpaceMonitor: Equatable, Sendable {
    static let hysteresis = 0.02
    static let defaultsKey = "ADK.lowSpaceArmed"

    /// True when the next crossing may fire.
    private(set) var armed: Bool

    init(armed: Bool = true) { self.armed = armed }

    /// `freeFraction` and `threshold` are 0…1. Returns true exactly when an alert should be posted now.
    mutating func observe(freeFraction: Double, threshold: Double) -> Bool {
        if freeFraction < threshold {
            guard armed else { return false }
            armed = false
            return true
        }
        if freeFraction > threshold + Self.hysteresis { armed = true }
        return false
    }

    /// The user moved the threshold: re-evaluate without firing. Already below the new level means quiet until it recovers.
    mutating func thresholdChanged(freeFraction: Double, threshold: Double) {
        if freeFraction < threshold { armed = false } else if freeFraction > threshold + Self.hysteresis { armed = true }
    }

    static func load(from defaults: UserDefaults) -> LowSpaceMonitor {
        LowSpaceMonitor(armed: defaults.object(forKey: defaultsKey) as? Bool ?? true)
    }

    func save(to defaults: UserDefaults) { defaults.set(armed, forKey: Self.defaultsKey) }
}
