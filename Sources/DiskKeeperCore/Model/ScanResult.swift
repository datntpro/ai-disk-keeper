import Foundation

/// Aggregate of item counts and sizes.
public struct UsageTotals: Codable, Sendable, Hashable {
    public var itemCount: Int
    public var allocatedBytes: Int64
    public var logicalBytes: Int64
    public var fileCount: Int

    public static let zero = UsageTotals()

    public init(itemCount: Int = 0, allocatedBytes: Int64 = 0, logicalBytes: Int64 = 0, fileCount: Int = 0) {
        self.itemCount = itemCount
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.fileCount = fileCount
    }

    public mutating func add(_ item: ScanItem) {
        itemCount += 1
        allocatedBytes += item.sizeAllocated
        logicalBytes += item.sizeLogical
        fileCount += item.fileCount
    }

    public static func + (l: UsageTotals, r: UsageTotals) -> UsageTotals {
        UsageTotals(itemCount: l.itemCount + r.itemCount,
                    allocatedBytes: l.allocatedBytes + r.allocatedBytes,
                    logicalBytes: l.logicalBytes + r.logicalBytes,
                    fileCount: l.fileCount + r.fileCount)
    }
}

/// Result of one scan.
///
/// Invariant: the sum over any single grouping (tier, category, tool, or project plus
/// ``unattributedTotals``) equals ``total``. Overlapping items (one path inside another) are NOT
/// detected here; the scan engine must emit non-overlapping items.
public struct ScanResult: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// Engine order preserved, de-duplicated by id (first occurrence wins).
    public let items: [ScanItem]
    public var warnings: [ScanWarning]
    public var startedAt: Date
    public var finishedAt: Date?
    public var wasCancelled: Bool

    public init(items: [ScanItem], warnings: [ScanWarning] = [], startedAt: Date,
                finishedAt: Date? = nil, wasCancelled: Bool = false) {
        self.schemaVersion = ScanResult.currentSchemaVersion
        self.items = ScanResult.deduplicated(items)
        self.warnings = warnings
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.wasCancelled = wasCancelled
    }

    private static func deduplicated(_ items: [ScanItem]) -> [ScanItem] {
        var seen = Set<ScanItem.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    // MARK: Aggregates

    private func totals<K: Hashable>(by key: (ScanItem) -> K?, where include: (ScanItem) -> Bool = { _ in true }) -> [K: UsageTotals] {
        var out: [K: UsageTotals] = [:]
        for item in items where include(item) {
            guard let k = key(item) else { continue }
            out[k, default: .zero].add(item)
        }
        return out
    }

    private func sum(where include: (ScanItem) -> Bool) -> UsageTotals {
        var t = UsageTotals.zero
        for item in items where include(item) { t.add(item) }
        return t
    }

    public var total: UsageTotals { sum { _ in true } }

    /// Always has all three tiers.
    public var totalsByTier: [RiskTier: UsageTotals] {
        var out = Dictionary(uniqueKeysWithValues: RiskTier.allCases.map { ($0, UsageTotals.zero) })
        for item in items { out[item.tier, default: .zero].add(item) }
        return out
    }

    public var totalsByCategory: [ItemCategory: UsageTotals] { totals(by: { $0.category }) }
    public var totalsByTool: [ToolID: UsageTotals] { totals(by: { $0.tool }) }

    /// Items grouped by `ProjectRef.id`; the first-seen `ProjectRef` is kept as the key.
    public var totalsByProject: [ProjectRef: UsageTotals] { totals(by: { $0.project }) }

    public var unattributedTotals: UsageTotals { sum { $0.project == nil } }
    public var reclaimable: UsageTotals { sum { $0.isSelectable } }
    public var bulkReclaimable: UsageTotals { sum { $0.isBulkSelectable } }

    /// H6: what cleaning every selectable item would really free (see ``ReclaimEstimate``), next to `reclaimable`'s
    /// shown size. Information only.
    public var reclaimableEstimate: ReclaimEstimate {
        ReclaimEstimate.make(items: items.filter(\.isSelectable))
    }

    /// Largest first by `sizeAllocated`; ties broken by id ascending. `limit <= 0` gives [].
    public func topItems(limit: Int) -> [ScanItem] {
        guard limit > 0 else { return [] }
        let sorted = items.sorted {
            $0.sizeAllocated != $1.sizeAllocated ? $0.sizeAllocated > $1.sizeAllocated : $0.id < $1.id
        }
        return Array(sorted.prefix(limit))
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, items, warnings, startedAt, finishedAt, wasCancelled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version <= ScanResult.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: c,
                debugDescription: "Unsupported schema version \(version)")
        }
        self.schemaVersion = version
        self.items = ScanResult.deduplicated(try c.decode([ScanItem].self, forKey: .items))
        self.warnings = try c.decodeIfPresent([ScanWarning].self, forKey: .warnings) ?? []
        self.startedAt = try c.decode(Date.self, forKey: .startedAt)
        self.finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.wasCancelled = try c.decodeIfPresent(Bool.self, forKey: .wasCancelled) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(items, forKey: .items)
        try c.encode(warnings, forKey: .warnings)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try c.encode(wasCancelled, forKey: .wasCancelled)
    }
}
