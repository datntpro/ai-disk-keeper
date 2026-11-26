import Foundation

/// The four things the monitor can show. Disk is always monitored (it feeds the low-space alert).
public enum MetricID: String, Codable, CaseIterable, Sendable, Hashable {
    case disk, cpu, memory, network
    public static let defaultOrder: [MetricID] = [.disk, .cpu, .memory, .network]
}

/// How metrics are drawn in the menu bar. `glyph` is the T47 look and what shows when nothing is in the bar.
public enum MenuBarStyle: String, Codable, CaseIterable, Sendable, Hashable {
    case glyph, readout, ridge, liveStrata
}

public enum NetworkUnits: String, Codable, CaseIterable, Sendable, Hashable {
    case bytes, bits
}
