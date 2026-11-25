import DiskKeeperCore
import Foundation
import Observation

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

@MainActor @Observable
public final class SettingsModel {
    public private(set) var settings: AppSettings
    public private(set) var lastError: String?
    /// Set when the settings file was unreadable and was replaced by defaults.
    public private(set) var loadWarning: ScanWarning?
    public private(set) var fdaStatus: FullDiskAccessStatus = .unknown
    public var availableTools: [ToolChoice]

    @ObservationIgnored public let scopeProvider: ScopeProvider
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let environment: PathEnvironment
    @ObservationIgnored private let probe: @Sendable () -> FullDiskAccessStatus

    public init(store: SettingsStore, environment: PathEnvironment, availableTools: [ToolChoice] = [],
                probe: @escaping @Sendable () -> FullDiskAccessStatus) {
        var (loaded, warning) = store.load()
        let bad = loaded.dropInvalidProjectRoots(environment: environment)
        if !bad.isEmpty {
            warning = warning ?? ScanWarning(
                kind: .other, path: store.fileURL.path,
                message: "Ignored project folders outside your home folder: \(bad.joined(separator: ", ")).")
        }
        self.store = store
        self.environment = environment
        self.settings = loaded
        self.loadWarning = warning
        self.availableTools = availableTools
        self.probe = probe
        self.scopeProvider = ScopeProvider(loaded.scanScope(environment: environment))
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
        do {
            try store.save(copy)
            lastError = nil
        } catch {
            lastError = "Couldn't save settings: \(error.localizedDescription)"
        }
    }

    static func describe(_ e: SettingsError) -> String {
        switch e {
        case .notAbsolute(let p): "“\(p)” isn't an absolute folder path."
        case .outsideHome(let p): "Project folders must be inside your home folder: “\(p)”."
        }
    }
}
