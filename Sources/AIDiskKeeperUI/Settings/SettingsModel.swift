import DiskKeeperCore
import Foundation
import Observation
import SwiftUI

/// A tool the user can switch on or off (built from the loaded rule sets).
public struct ToolChoice: Sendable, Hashable, Identifiable {
    public let id: ToolID
    public let name: String
    public init(id: ToolID, name: String) { self.id = id; self.name = name }
}

/// Thread-safe holder of the scope the next scan should use. Engines are built off the main actor, so they
/// read this instead of the main-actor model.
public final class ScopeProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var scope: ScanScope
    public init(_ scope: ScanScope = .unrestricted) { self.scope = scope }
    public var current: ScanScope { lock.lock(); defer { lock.unlock() }; return scope }
    func set(_ new: ScanScope) { lock.lock(); scope = new; lock.unlock() }
}

/// Thread-safe handle to the one scan cache: `current` is nil while the user has it switched off.
public final class ScanCacheProvider: @unchecked Sendable {
    public let cache: SizeCache
    private let lock = NSLock()
    private var enabled: Bool
    public init(cache: SizeCache, enabled: Bool) { self.cache = cache; self.enabled = enabled }
    public var current: SizeCache? { lock.lock(); defer { lock.unlock() }; return enabled ? cache : nil }
    func set(enabled: Bool) { lock.lock(); self.enabled = enabled; lock.unlock() }
}

@MainActor @Observable
public final class SettingsModel {
    public private(set) var settings: AppSettings
    public private(set) var lastError: String?
    /// Set when the settings file was unreadable and was replaced by defaults.
    public private(set) var loadWarning: ScanWarning?
    public private(set) var fdaStatus: FullDiskAccessStatus = .unknown
    public var availableTools: [ToolChoice]
    /// Bumped on every language change; views read it (and use it as an `.id`) so they rebuild with the new language.
    public private(set) var languageRevision = 0

    @ObservationIgnored public let scopeProvider: ScopeProvider
    @ObservationIgnored public let scanCache: ScanCacheProvider
    /// What the engines enforce: the policy in memory (the truth even when saving fails), never a re-read of the file.
    @ObservationIgnored public let userPolicyProvider: UserPolicyProvider
    /// settings.json existed but couldn't be read at launch, so the user's Keep/ignore choices are unknown: cleanup is
    /// blocked until the user acknowledges the reset in Settings → Rules.
    public private(set) var userPolicyUnreadable: Bool
    /// The last change to the rules/overrides could not be saved (it is still enforced until quit).
    public private(set) var userPolicySaveFailed = false
    /// Set after "Clear scan cache" finishes; the view shows a confirmation.
    public private(set) var scanCacheCleared = false
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored let environment: PathEnvironment
    @ObservationIgnored private let probe: @Sendable () -> FullDiskAccessStatus

    public init(store: SettingsStore, environment: PathEnvironment, availableTools: [ToolChoice] = [],
                probe: @escaping @Sendable () -> FullDiskAccessStatus) {
        var (loaded, warning) = store.load()   // carries a `code`; the UI words it via `uiMessage`
        let bad = loaded.dropInvalidProjectRoots(environment: environment)
        if !bad.isEmpty {
            warning = warning ?? ScanWarning(
                kind: .other, path: store.fileURL.path,
                message: loc("settings.warning.badRoots", "Ignored project folders outside your home folder: \(bad.joined(separator: ", ")).")
            )
        }
        self.store = store
        self.environment = environment
        self.settings = loaded
        self.loadWarning = warning
        self.availableTools = availableTools
        self.probe = probe
        var unreadable = false
        if case .settingsUnreadable? = warning?.code { unreadable = true }
        self.userPolicyUnreadable = unreadable
        self.userPolicyProvider = UserPolicyProvider(policy: loaded.userPolicy, trusted: !unreadable)
        self.scopeProvider = ScopeProvider(loaded.scanScope(environment: environment))
        self.scanCache = ScanCacheProvider(
            cache: SizeCache(fileURL: SizeCache.defaultFileURL(environment: environment)), enabled: loaded.useScanCache)
        refreshFullDiskAccess()
    }

    public var scanScope: ScanScope { settings.scanScope(environment: environment) }
    public var allToolsDisabled: Bool {
        !availableTools.isEmpty && availableTools.allSatisfy { settings.disabledTools.contains($0.id) }
    }

    public func refreshFullDiskAccess() { fdaStatus = probe() }
    public func dismissLoadWarning() { loadWarning = nil }
    public func clearError() { lastError = nil }

    public func isEnabled(_ tool: ToolID) -> Bool { settings.isEnabled(tool) }
    public func setTool(_ tool: ToolID, enabled: Bool) { mutate { $0.setTool(tool, enabled: enabled) } }
    public func addExcludedPath(_ url: URL) { mutate { try $0.addExcludedPath(url, environment: environment) } }
    public func removeExcludedPath(_ stored: String) { mutate { $0.removeExcludedPath(stored) } }
    public func addProjectRoot(_ url: URL) { mutate { try $0.addProjectRoot(url, environment: environment) } }
    public func removeProjectRoot(_ stored: String) { mutate { $0.removeProjectRoot(stored) } }
    public func resetScopeToDefaults() { mutate { $0.resetScopeToDefaults() } }
    public var language: AppLanguage { AppLanguage(storedValue: settings.language) }

    /// Persists the choice, switches the in-app language immediately and remembers it for AppKit's own menus
    /// (`AppleLanguages`), which follow after a relaunch.
    public func setLanguage(_ new: AppLanguage) {
        mutate { $0.language = new.rawValue }
        L10n.apply(new)
        languageRevision += 1
        Self.persistAppleLanguages(new)
    }

    static func persistAppleLanguages(_ l: AppLanguage, defaults: UserDefaults = .standard) {
        if l == .system { defaults.removeObject(forKey: "AppleLanguages") } else { defaults.set([l.rawValue], forKey: "AppleLanguages") }
    }

    public func setUseScanCache(_ on: Bool) { mutate { $0.useScanCache = on } }
    public func clearScanCache() {
        scanCacheCleared = false
        let cache = scanCache.cache
        Task { [weak self] in
            await cache.clear()
            self?.scanCacheCleared = true
        }
    }

    public func setShowMenuBarItem(_ on: Bool) { mutate { $0.showMenuBarItem = on } }
    public func setMenuBarShowsFreeSpace(_ on: Bool) { mutate { $0.menuBarShowsFreeSpace = on } }
    public func setLowSpaceAlertEnabled(_ on: Bool) { mutate { $0.lowSpaceAlertEnabled = on } }
    /// Clamped to 1…50.
    public func setLowSpaceThresholdPercent(_ percent: Int) { mutate { $0.setLowSpaceThreshold(percent: percent) } }

    public func setPublishHostStatus(_ on: Bool) { mutate { $0.publishHostStatus = on } }
    /// Clamped to 1…60.
    public func setAutoResumeMinutes(_ minutes: Int) { mutate { $0.autoResumeMinutes = AppSettings.clampAutoResume(minutes) } }

    // System monitor (T50)
    public func setMetric(_ m: MetricID, monitored: Bool) { mutate { $0.setMetric(m, monitored: monitored) } }
    public func setMetric(_ m: MetricID, inMenuBar on: Bool) { mutate { $0.setMetric(m, inMenuBar: on) } }
    public func moveMetric(_ m: MetricID, by offset: Int) { mutate { $0.moveMetric(m, by: offset) } }
    public func moveMetrics(from source: IndexSet, to destination: Int) {
        mutate { $0.monitorOrder.move(fromOffsets: source, toOffset: destination) }
    }
    public func setMenuBarStyle(_ style: MenuBarStyle) { mutate { $0.menuBarStyle = style } }
    public func setMenuBarRefresh(seconds: Int) { mutate { $0.menuBarRefreshSeconds = SamplingPolicy.snapBarSeconds(seconds) } }
    public func setNetworkUnits(_ units: NetworkUnits) { mutate { $0.networkUnits = units } }
    public func setShowsTopProcesses(_ on: Bool) { mutate { $0.popoverShowsTopProcesses = on } }
    public func setHistoryMinutes(_ minutes: Int) { mutate { $0.popoverHistoryMinutes = AppSettings.snapHistoryMinutes(minutes) } }

    public func setScanFrequency(_ f: ScanFrequency) { mutate { $0.scanFrequency = f } }
    public func setScheduledSafeAlertGB(_ gb: Int) { mutate { $0.scheduledSafeAlertGB = min(max(gb, 1), 500) } }
    public func setScheduledGrowthAlertGB(_ gb: Int) { mutate { $0.scheduledGrowthAlertGB = min(max(gb, 1), 500) } }
    public func setScheduledSkipOnBattery(_ on: Bool) { mutate { $0.scheduledSkipOnBattery = on } }
    public func setWorktreeIdleHours(_ hours: Int) { mutate { $0.worktreeIdleHours = AppSettings.clampWorktreeIdleHours(hours) } }
    public func setUseGitHubCLIForPRs(_ on: Bool) { mutate { $0.useGitHubCLIForPRs = on } }

    // User rules (T23)
    public func setUserRulesEnabled(_ on: Bool) { mutate { $0.userRulesEnabled = on } }
    public func ignoreItem(_ id: String) { mutate { $0.ignoredItemIDs.insert(id) } }
    public func unignoreItem(_ id: String) { mutate { $0.ignoredItemIDs.remove(id) } }
    public func isRuleDisabled(_ id: String) -> Bool { settings.disabledRuleIDs.contains(id) }
    public func setRule(_ id: String, disabled: Bool) {
        mutate { if disabled { $0.disabledRuleIDs.insert(id) } else { $0.disabledRuleIDs.remove(id) } }
    }
    /// Only a stricter tier than `item.tier` is stored (Review for Safe items; Keep for Safe/Review items).
    public func overrideTier(of item: ScanItem, to tier: RiskTier) {
        guard UserPolicyChoices.offered(for: item.tier).contains(tier) else { return }
        mutate { $0.tierOverrides[item.id] = tier }
    }
    public func resetOverride(_ key: String) { mutate { $0.tierOverrides[key] = nil } }
    public func hasOverride(_ item: ScanItem) -> Bool { settings.userPolicy.override(for: item) != nil }

    /// "Continue with empty rules": accepts that the unreadable settings were replaced by defaults.
    public func acknowledgeUnreadablePolicy() {
        userPolicyUnreadable = false
        userPolicyProvider.set(trusted: true)
    }

    public func setOnboardingCompleted(_ done: Bool) { mutate { $0.hasCompletedOnboarding = done } }

    /// Applies `change` to a copy; on failure the settings stay unchanged and `lastError` explains why.
    private func mutate(_ change: (inout AppSettings) throws -> Void) {
        var copy = settings
        do {
            try change(&copy)
        } catch let e as SettingsError {
            lastError = Self.describe(e)
            return
        } catch {
            lastError = "\(error)"
            return
        }
        guard copy != settings else { return }
        settings = copy
        scopeProvider.set(copy.scanScope(environment: environment))
        scanCache.set(enabled: copy.useScanCache)
        userPolicyProvider.set(policy: copy.userPolicy)
        do {
            try store.save(copy)
            lastError = nil
            userPolicySaveFailed = false
        } catch {
            userPolicySaveFailed = true
            lastError = loc("settings.error.save", "Couldn't save settings: \(error.localizedDescription)")
        }
    }

    static func describe(_ e: SettingsError) -> String {
        switch e {
        case .notAbsolute(let p): loc("settings.error.notAbsolute", "“\(p)” isn't an absolute folder path.")
        case .outsideHome(let p): loc("settings.error.outsideHome", "Project folders must be inside your home folder: “\(p)”.")
        }
    }
}
