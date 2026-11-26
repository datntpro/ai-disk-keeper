import Foundation

/// What one module can reclaim, by tier. Counts only the items of the stage(s) that cover the module; it is not
/// deduplicated against other stages (the hero totals are, see ``CareTotals``).
public struct ModuleSummary: Sendable, Hashable, Codable {
    public let module: CareModule
    public var safeBytes: Int64
    public var reviewBytes: Int64
    public var keepBytes: Int64
    public var itemCount: Int
    public var totalBytes: Int64 { safeBytes + reviewBytes + keepBytes }

    public init(module: CareModule, safeBytes: Int64 = 0, reviewBytes: Int64 = 0, keepBytes: Int64 = 0,
                itemCount: Int = 0) {
        self.module = module
        self.safeBytes = safeBytes
        self.reviewBytes = reviewBytes
        self.keepBytes = keepBytes
        self.itemCount = itemCount
    }

    mutating func add(bytes: Int64, tier: RiskTier) {
        switch tier {
        case .safe: safeBytes += bytes
        case .review: reviewBytes += bytes
        case .keep: keepBytes += bytes
        }
        itemCount += 1
    }

    mutating func merge(_ other: ModuleSummary) {
        safeBytes += other.safeBytes
        reviewBytes += other.reviewBytes
        keepBytes += other.keepBytes
        itemCount += other.itemCount
    }
}

/// The hero numbers: every physical byte is counted once, over the deduplicated item set.
public struct CareTotals: Sendable, Hashable, Codable {
    public var safeBytes: Int64 = 0
    public var reviewBytes: Int64 = 0
    public var keepBytes: Int64 = 0
    public var itemCount: Int = 0
    public var totalBytes: Int64 { safeBytes + reviewBytes + keepBytes }
    public init() {}
}

/// Growth of AI-tool data since the previous completed scan of the same scope.
public struct CareGrowth: Sendable, Hashable, Codable {
    public let since: Date
    /// Signed: current − previous AI-tool bytes (all tiers).
    public let aiToolsDelta: Int64
    /// Signed delta for the tools present in either scan.
    public let perTool: [ToolID: Int64]

    public init(since: Date, aiToolsDelta: Int64, perTool: [ToolID: Int64]) {
        self.since = since
        self.aiToolsDelta = aiToolsDelta
        self.perTool = perTool
    }
}

public struct CareReport: Sendable {
    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let wasCancelled: Bool
    public let summaries: [CareModule: ModuleSummary]
    public let totals: CareTotals
    public let warnings: [ScanWarning]
    public let failedStages: [CareStage]
    /// nil on the first scan, on a cancelled scan, or after a scope change.
    public let growth: CareGrowth?
}

/// How an item counts toward the numbers. Duplicates follow the honest-savings rule: the suggested keeper frees
/// nothing and is not counted; a member that shares storage (clone/hard link) is listed but counts 0 bytes.
/// Nothing is ever re-tiered.
enum CareCounting {
    static func contribution(of item: ScanItem) -> (bytes: Int64, counted: Bool) {
        guard item.category == .duplicate else { return (item.sizeAllocated, true) }
        if item.flags.contains(.suggestedKeeper) { return (0, false) }
        if item.flags.contains(.sharedStorage) { return (0, true) }
        return (item.sizeAllocated, true)
    }
}

/// Accumulates one scan: per-stage module summaries, physically deduplicated totals, per-tool AI bytes.
struct CareTally {
    private var claims = CareByteTrie()
    private(set) var summaries: [CareModule: ModuleSummary] = [:]
    private(set) var totals = CareTotals()
    private(set) var perTool: [String: Int64] = [:]
    private var stageSummaries: [CareStage: [CareModule: ModuleSummary]] = [:]

    mutating func begin(_ stage: CareStage, modules: [CareModule]) {
        var s: [CareModule: ModuleSummary] = [:]
        for m in modules { s[m] = ModuleSummary(module: m) }
        stageSummaries[stage] = s
    }

    /// `physical` is the item's physical path. The first stage to deliver a path wins the totals.
    mutating func add(_ item: ScanItem, physical: String, stage: CareStage) {
        let (bytes, counted) = CareCounting.contribution(of: item)
        // Claim even a 0-byte or keeper member, so what sits inside it is not counted again.
        let net = claims.claim(physical, bytes: counted ? bytes : 0)
        guard counted else { return }
        let module = CareModule(category: item.category)
        stageSummaries[stage, default: [:]][module, default: ModuleSummary(module: module)]
            .add(bytes: bytes, tier: item.tier)
        summaries[module, default: ModuleSummary(module: module)].add(bytes: bytes, tier: item.tier)
        guard let net else { return }
        switch item.tier {
        case .safe: totals.safeBytes += net
        case .review: totals.reviewBytes += net
        case .keep: totals.keepBytes += net
        }
        totals.itemCount += 1
        if item.category == .aiToolData { perTool[item.tool.rawValue, default: 0] += net }
    }

    func stageSummary(_ stage: CareStage) -> [ModuleSummary] {
        CareModule.allCases.compactMap { stageSummaries[stage]?[$0] }
    }
}

/// Physical paths already counted in the totals, with the bytes counted under each subtree.
/// `claim` returns nil when the path is equal to or inside a counted path (nothing to add). When the new path
/// *contains* counted paths it returns its bytes minus what is already counted below it, so a parent that arrives
/// after its child (an app-leftover folder after a rule's log file) counts only the remainder.
struct CareByteTrie: Sendable {
    private struct Node: Sendable {
        var children: [String: Int] = [:]
        var counted = false
        var subtree: Int64 = 0   // bytes counted at or below this node
    }
    private var nodes: [Node] = [Node()]

    mutating func claim(_ path: String, bytes: Int64) -> Int64? {
        var trail = [0]
        for component in PathCanonicalizer.key(path).components {
            if nodes[trail.last!].counted { return nil }
            if let next = nodes[trail.last!].children[component] {
                trail.append(next)
            } else {
                nodes.append(Node())
                nodes[trail.last!].children[component] = nodes.count - 1
                trail.append(nodes.count - 1)
            }
        }
        let last = trail.last!
        if nodes[last].counted { return nil }
        let net = max(0, bytes - nodes[last].subtree)
        nodes[last].counted = true
        for i in trail { nodes[i].subtree += net }
        return net
    }
}
