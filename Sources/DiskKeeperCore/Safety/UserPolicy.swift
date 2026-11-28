import Foundation

/// What the user has asked for on top of the rules: items to hide, rules to switch off and tier overrides.
/// Every effect is monotone: it can drop an item or move it toward Keep, never the other way, and it can never
/// make a protected path removable (the protected-path guard does not read this).
public struct UserPolicy: Sendable, Hashable {
    public var ignoredItemIDs: Set<String>
    public var disabledRuleIDs: Set<String>
    /// Key = item id or rule id; the item id wins.
    public var tierOverrides: [String: RiskTier]

    public static let empty = UserPolicy()

    public init(ignoredItemIDs: Set<String> = [], disabledRuleIDs: Set<String> = [],
                tierOverrides: [String: RiskTier] = [:]) {
        self.ignoredItemIDs = ignoredItemIDs
        self.disabledRuleIDs = disabledRuleIDs
        self.tierOverrides = tierOverrides
    }

    public var isEmpty: Bool { ignoredItemIDs.isEmpty && disabledRuleIDs.isEmpty && tierOverrides.isEmpty }

    /// True when the user hid the item or switched its rule off.
    public func hides(_ item: ScanItem) -> Bool {
        ignoredItemIDs.contains(item.id) || disabledRuleIDs.contains(item.ruleID)
    }

    /// The override that applies to this item (item id first, then rule id), if any.
    public func override(for item: ScanItem) -> RiskTier? {
        tierOverrides[item.id] ?? tierOverrides[item.ruleID]
    }

    /// `item.tier` with the user's override applied, only when it is stricter. Never lower than `item.tier`.
    public func effectiveTier(for item: ScanItem) -> RiskTier {
        guard let o = override(for: item), o > item.tier else { return item.tier }
        return o
    }

    /// Reads the policy persisted in settings.json. Missing or unreadable settings give the empty policy.
    public static func load(environment: PathEnvironment) -> UserPolicy {
        let (settings, _) = SettingsStore(environment: environment).load()
        return settings.userPolicy
    }
}

/// Where user rule files live and whether they are read at all.
public enum UserRulesDirectory {
    public static func defaultURL(environment: PathEnvironment) -> URL { environment.userRulesDirectory }

    /// The folder rule loaders should read, or nil when the user switched user rules off. Not created here.
    public static func activeURL(environment: PathEnvironment) -> URL? {
        let (settings, _) = SettingsStore(environment: environment).load()
        return settings.userRulesEnabled ? defaultURL(environment: environment) : nil
    }

    /// Creates the folder (0700). Call only when the user asks for it ("Open rules folder"), never at launch.
    @discardableResult
    public static func ensureExists(environment: PathEnvironment) throws -> URL {
        let url = defaultURL(environment: environment)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }
}
