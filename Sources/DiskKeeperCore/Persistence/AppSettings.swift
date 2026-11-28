import Foundation

public enum SettingsError: Error, Equatable, Sendable {
    case notAbsolute(String)
    case outsideHome(String)
}

/// User settings. Paths under home are stored as `~/…`; tools are enabled unless listed in `disabledTools`.
public struct AppSettings: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = AppSettings.currentSchemaVersion
    public var hasCompletedOnboarding = false
    public var projectRoots: [String]
    public var excludedPaths: [String]
    /// Empty = all enabled (new tools are on by default).
    public var disabledTools: Set<ToolID>
    /// UI language choice: "system" (default), "en" or "vi". Kept as a raw string; the UI maps unknown values to system.
    public var language: String = "system"
    /// Menu bar extra (T47). Shown by default, glyph only.
    public var showMenuBarItem = true
    /// Optional free-space text next to the glyph.
    public var menuBarShowsFreeSpace = false
    public var lowSpaceAlertEnabled = true
    /// Alert when free space falls below this percent of the volume. Kept within `thresholdRange`.
    public var lowSpaceThresholdPercent = AppSettings.defaultLowSpaceThresholdPercent

    // System monitor (T50). All additive with defaults; the default menu bar is unchanged from T47.
    /// Order of the metrics in the popover, the Settings list and the bar. Always a permutation of `MetricID.allCases`.
    public var monitorOrder: [MetricID] = MetricID.defaultOrder
    /// Disabled = not sampled, not in the popover, not in the bar. Disk can't be disabled.
    public var monitorDisabled: Set<MetricID> = []
    /// CPU / memory / network drawn in the bar. Disk in the bar is `menuBarShowsFreeSpace`.
    public var menuBarMetrics: Set<MetricID> = []
    public var menuBarStyle: MenuBarStyle = .readout
    public var menuBarRefreshSeconds = 5
    public var networkUnits: NetworkUnits = .bytes
    public var popoverShowsTopProcesses = false
    public var popoverHistoryMinutes = 1

    /// T25: reuse sizes of unchanged items between scans (validated against the file system journal).
    public var useScanCache = true
    // Scheduled scans (T22). Off by default; a scheduled run is the read-only Care Scan.
    public var scanFrequency: ScanFrequency = .off
    public var scheduledSafeAlertGB = 5
    public var scheduledGrowthAlertGB = 2
    public var scheduledSkipOnBattery = true
    /// Process control (H5): minutes until a paused process is resumed by itself. Always 1...60, never "forever".
    public var autoResumeMinutes = AppSettings.defaultAutoResumeMinutes
    public static let autoResumeRange = 1...60
    public static let defaultAutoResumeMinutes = 15

    /// H2: publish `status.json` for coding agents while the app runs (D10: on by default).
    public var publishHostStatus = true

    public static let historyMinuteChoices = [1, 5]

    public static let lowSpaceThresholdRange = 5...30
    public static let defaultLowSpaceThresholdPercent = 15

    public static let defaultProjectRoots = ["~", "~/orca/workspaces", "~/Developer", "~/code", "~/src", "~/projects"]

    public static let defaults = AppSettings(projectRoots: defaultProjectRoots, excludedPaths: [], disabledTools: [])

    public init(hasCompletedOnboarding: Bool = false, projectRoots: [String] = AppSettings.defaultProjectRoots,
                excludedPaths: [String] = [], disabledTools: Set<ToolID> = [], language: String = "system") {
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.projectRoots = projectRoots
        self.excludedPaths = excludedPaths
        self.disabledTools = disabledTools
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, hasCompletedOnboarding, projectRoots, excludedPaths, disabledTools, language
        case showMenuBarItem, menuBarShowsFreeSpace, lowSpaceAlertEnabled, lowSpaceThresholdPercent
        case monitorOrder, monitorDisabled, menuBarMetrics, menuBarStyle, menuBarRefreshSeconds, networkUnits
        case popoverShowsTopProcesses, popoverHistoryMinutes, useScanCache
        case publishHostStatus
        case scanFrequency, scheduledSafeAlertGB, scheduledGrowthAlertGB, scheduledSkipOnBattery, autoResumeMinutes
    }

    /// Lenient: unknown keys are ignored and missing keys take defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        projectRoots = try c.decodeIfPresent([String].self, forKey: .projectRoots) ?? Self.defaultProjectRoots
        excludedPaths = try c.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
        disabledTools = try c.decodeIfPresent(Set<ToolID>.self, forKey: .disabledTools) ?? []
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "system"
        showMenuBarItem = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarItem) ?? true
        menuBarShowsFreeSpace = try c.decodeIfPresent(Bool.self, forKey: .menuBarShowsFreeSpace) ?? false
        lowSpaceAlertEnabled = try c.decodeIfPresent(Bool.self, forKey: .lowSpaceAlertEnabled) ?? true
        let percent = try c.decodeIfPresent(Int.self, forKey: .lowSpaceThresholdPercent) ?? Self.defaultLowSpaceThresholdPercent
        lowSpaceThresholdPercent = Self.clampThreshold(percent)
        monitorOrder = Self.normalizedOrder(try c.decodeIfPresent([String].self, forKey: .monitorOrder) ?? [])
        monitorDisabled = Self.metricSet(try c.decodeIfPresent([String].self, forKey: .monitorDisabled) ?? []).subtracting([.disk])
        menuBarMetrics = Self.metricSet(try c.decodeIfPresent([String].self, forKey: .menuBarMetrics) ?? []).subtracting([.disk])
        menuBarStyle = (try c.decodeIfPresent(String.self, forKey: .menuBarStyle)).flatMap(MenuBarStyle.init(rawValue:)) ?? .readout
        menuBarRefreshSeconds = SamplingPolicy.snapBarSeconds(try c.decodeIfPresent(Int.self, forKey: .menuBarRefreshSeconds) ?? 5)
        networkUnits = (try c.decodeIfPresent(String.self, forKey: .networkUnits)).flatMap(NetworkUnits.init(rawValue:)) ?? .bytes
        popoverShowsTopProcesses = try c.decodeIfPresent(Bool.self, forKey: .popoverShowsTopProcesses) ?? false
        popoverHistoryMinutes = Self.snapHistoryMinutes(try c.decodeIfPresent(Int.self, forKey: .popoverHistoryMinutes) ?? 1)
        useScanCache = try c.decodeIfPresent(Bool.self, forKey: .useScanCache) ?? true
        publishHostStatus = try c.decodeIfPresent(Bool.self, forKey: .publishHostStatus) ?? true
        scanFrequency = (try c.decodeIfPresent(String.self, forKey: .scanFrequency)).flatMap(ScanFrequency.init(rawValue:)) ?? .off
        scheduledSafeAlertGB = min(max(try c.decodeIfPresent(Int.self, forKey: .scheduledSafeAlertGB) ?? 5, 1), 500)
        scheduledGrowthAlertGB = min(max(try c.decodeIfPresent(Int.self, forKey: .scheduledGrowthAlertGB) ?? 2, 1), 500)
        scheduledSkipOnBattery = try c.decodeIfPresent(Bool.self, forKey: .scheduledSkipOnBattery) ?? true
        autoResumeMinutes = Self.clampAutoResume(try c.decodeIfPresent(Int.self, forKey: .autoResumeMinutes) ?? Self.defaultAutoResumeMinutes)
    }

    /// Unknown and duplicate ids are dropped; missing ones are appended in the default order.
    public static func normalizedOrder(_ raw: [String]) -> [MetricID] {
        var seen = Set<MetricID>()
        var out = raw.compactMap(MetricID.init(rawValue:)).filter { seen.insert($0).inserted }
        out += MetricID.defaultOrder.filter { !seen.contains($0) }
        return out
    }

    private static func metricSet(_ raw: [String]) -> Set<MetricID> { Set(raw.compactMap(MetricID.init(rawValue:))) }

    public static func snapHistoryMinutes(_ m: Int) -> Int { m >= 5 ? 5 : 1 }

    /// Metrics that are sampled and shown, in the user's order.
    public var enabledMetricsInOrder: [MetricID] { monitorOrder.filter { !monitorDisabled.contains($0) } }
    public func isMonitored(_ m: MetricID) -> Bool { m == .disk || !monitorDisabled.contains(m) }
    /// Whether `m` is drawn in the bar (disk = the T47 free-space text).
    public func isInMenuBar(_ m: MetricID) -> Bool {
        m == .disk ? menuBarShowsFreeSpace : (menuBarMetrics.contains(m) && isMonitored(m))
    }
    /// The bar's metrics in the user's order.
    public var menuBarMetricsInOrder: [MetricID] { monitorOrder.filter { isInMenuBar($0) } }

    public mutating func setMetric(_ m: MetricID, monitored: Bool) {
        guard m != .disk else { return }
        if monitored { monitorDisabled.remove(m) } else { monitorDisabled.insert(m) }
    }
    public mutating func setMetric(_ m: MetricID, inMenuBar on: Bool) {
        if m == .disk { menuBarShowsFreeSpace = on; return }
        if on { menuBarMetrics.insert(m) } else { menuBarMetrics.remove(m) }
    }
    /// Moves one step (negative = up); a no-op at the ends.
    public mutating func moveMetric(_ m: MetricID, by offset: Int) {
        guard let i = monitorOrder.firstIndex(of: m) else { return }
        let j = i + offset
        guard monitorOrder.indices.contains(j) else { return }
        monitorOrder.swapAt(i, j)
    }

    public static func clampThreshold(_ percent: Int) -> Int {
        min(max(percent, lowSpaceThresholdRange.lowerBound), lowSpaceThresholdRange.upperBound)
    }

    public static func clampAutoResume(_ minutes: Int) -> Int {
        min(max(minutes, autoResumeRange.lowerBound), autoResumeRange.upperBound)
    }

    public mutating func setLowSpaceThreshold(percent: Int) { lowSpaceThresholdPercent = Self.clampThreshold(percent) }

    public func scanScope(environment: PathEnvironment) -> ScanScope {
        ScanScope(excludedPaths: Self.dedupe(excludedPaths.map { Self.expand($0, environment) }),
                  disabledTools: disabledTools,
                  projectRoots: Self.dedupe(projectRoots.map { Self.expand($0, environment) }
                      .filter { Self.isInsideHome($0, environment) }))
    }

    // MARK: Editing

    /// Excluding is always safe, so any absolute path is accepted. A child of an existing exclusion is a no-op;
    /// a new parent absorbs its existing children.
    public mutating func addExcludedPath(_ url: URL, environment: PathEnvironment) throws(SettingsError) {
        let path = try Self.normalized(url)
        let key = PathCanonicalizer.key(path).components
        for existing in excludedPaths {
            let ex = PathCanonicalizer.key(Self.expand(existing, environment)).components
            if ex.count <= key.count, key.prefix(ex.count) == ex[...] { return }
        }
        excludedPaths.removeAll {
            let ex = PathCanonicalizer.key(Self.expand($0, environment)).components
            return key.count <= ex.count && ex.prefix(key.count) == key[...]
        }
        excludedPaths.append(Self.store(path, environment))
    }

    public mutating func addProjectRoot(_ url: URL, environment: PathEnvironment) throws(SettingsError) {
        let path = try Self.normalized(url)
        let home = PathCanonicalizer.key(environment.home).components
        let key = PathCanonicalizer.key(path).components
        guard key.count >= home.count, key.prefix(home.count) == home[...] else {
            throw SettingsError.outsideHome(path)
        }
        if projectRoots.contains(where: { PathCanonicalizer.key(Self.expand($0, environment)) == PathCanonicalizer.key(path) }) { return }
        projectRoots.append(Self.store(path, environment))
    }

    public mutating func removeExcludedPath(_ stored: String) { excludedPaths.removeAll { $0 == stored } }
    public mutating func removeProjectRoot(_ stored: String) { projectRoots.removeAll { $0 == stored } }

    public mutating func setTool(_ tool: ToolID, enabled: Bool) {
        if enabled { disabledTools.remove(tool) } else { disabledTools.insert(tool) }
    }

    public func isEnabled(_ tool: ToolID) -> Bool { !disabledTools.contains(tool) }

    public mutating func resetScopeToDefaults() {
        projectRoots = Self.defaultProjectRoots
        excludedPaths = []
        disabledTools = []
    }

    // MARK: Paths

    private static func normalized(_ url: URL) throws(SettingsError) -> String {
        let path = url.path
        guard PathNormalization.isAbsolute(path), !PathNormalization.containsNUL(path) else {
            throw SettingsError.notAbsolute(path)
        }
        return PathNormalization.lexical(path)
    }

    static func expand(_ stored: String, _ env: PathEnvironment) -> String {
        if stored == "~" { return env.home }
        if stored.hasPrefix("~/") { return PathNormalization.lexical(env.home + "/" + stored.dropFirst(2)) }
        return PathNormalization.lexical(stored)
    }

    static func store(_ path: String, _ env: PathEnvironment) -> String {
        let home = PathNormalization.lexical(env.home)
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Removes stored project roots that are not absolute or are outside home; returns what was removed.
    @discardableResult
    public mutating func dropInvalidProjectRoots(environment: PathEnvironment) -> [String] {
        let bad = projectRoots.filter { !Self.isInsideHome(Self.expand($0, environment), environment) }
        projectRoots.removeAll { bad.contains($0) }
        return bad
    }

    /// Roots from a hand-edited file are untrusted: absolute and inside home, or dropped.
    static func isInsideHome(_ path: String, _ env: PathEnvironment) -> Bool {
        guard PathNormalization.isAbsolute(path) else { return false }
        let home = PathCanonicalizer.key(env.home).components
        let key = PathCanonicalizer.key(path).components
        return key.count >= home.count && key.prefix(home.count) == home[...]
    }

    private static func dedupe(_ paths: [String]) -> [String] {
        var seen = Set<PathKey>()
        return paths.filter { seen.insert(PathCanonicalizer.key($0)).inserted }
    }
}
