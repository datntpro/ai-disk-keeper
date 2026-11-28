import Foundation

/// One cleanable (or report-only) thing found by a scan. Pure data.
public struct ScanItem: Identifiable, Codable, Sendable, Hashable {
    public typealias ID = String

    /// Stable across scans: ``makeID(ruleID:url:)``.
    public let id: ID
    /// File URL, lexically normalized (no ".", "..", "//" or trailing "/"); `/private` and symlinks are
    /// preserved, so it matches `FileSizer` paths.
    public let url: URL
    public var displayName: String
    public var tool: ToolID
    public var category: ItemCategory
    public var project: ProjectRef?
    /// Bytes on disk (what we show/sum).
    public var sizeAllocated: Int64
    /// Apparent size.
    public var sizeLogical: Int64
    public var fileCount: Int
    /// Newest mtime in the tree; nil if unknown.
    public var lastModified: Date?
    public var tier: RiskTier
    /// User-facing copy.
    public var explanation: String
    public var ruleID: String
    public var cleanupMethod: CleanupMethod
    /// Bundle id that must not be running.
    public var requiresAppQuit: String?
    public var flags: Set<ItemFlag>
    /// Duplicate group (`"dup:<sha256-prefix>:<size>"`) or an app and its leftovers (`"app:<bundleID>"`).
    /// Free-form, at most 200 characters; nil for items that belong to no group.
    public var groupID: String?
    /// Name and pid of the process that keeps this item busy (set only by the in-use adjuster, with ``ItemFlag/inUse``).
    /// The UI words the sentence; no English is stored in `explanation`.
    public var inUseBy: String?
    public var inUsePID: Int32?
    /// H6: bytes that deleting this item would really free on APFS (nil = unknown / not measured). Never above
    /// `sizeAllocated`. Information only: it changes no tier and blocks nothing.
    public var reclaimableBytes: Int64?
    /// H6: `reclaimableBytes` includes files that could not be probed, so the real number may be lower.
    public var reclaimIsEstimate: Bool

    public init(id: ID? = nil,
                url: URL,
                displayName: String,
                tool: ToolID,
                category: ItemCategory,
                project: ProjectRef? = nil,
                sizeAllocated: Int64,
                sizeLogical: Int64,
                fileCount: Int,
                lastModified: Date?,
                tier: RiskTier,
                explanation: String,
                ruleID: String,
                cleanupMethod: CleanupMethod = .trash,
                requiresAppQuit: String? = nil,
                flags: Set<ItemFlag> = [],
                groupID: String? = nil,
                inUseBy: String? = nil,
                inUsePID: Int32? = nil,
                reclaimableBytes: Int64? = nil,
                reclaimIsEstimate: Bool = false) {
        precondition(url.isFileURL, "ScanItem requires a file URL")
        let normalized = URL(fileURLWithPath: PathNormalization.lexical(url.absoluteURL.path))
        self.url = normalized
        self.id = id ?? ScanItem.makeID(ruleID: ruleID, url: normalized)
        self.displayName = displayName
        self.tool = tool
        self.category = category
        self.project = project
        self.sizeAllocated = sizeAllocated
        self.sizeLogical = sizeLogical
        self.fileCount = fileCount
        self.lastModified = lastModified
        self.tier = tier
        self.explanation = explanation
        self.ruleID = ruleID
        self.cleanupMethod = cleanupMethod
        self.requiresAppQuit = requiresAppQuit
        self.flags = flags
        self.groupID = groupID
        self.inUseBy = inUseBy
        self.inUsePID = inUsePID
        self.reclaimableBytes = reclaimableBytes.map { max(0, min($0, sizeAllocated)) }
        self.reclaimIsEstimate = reclaimIsEstimate
    }

    /// H6: the item's `reclaimableBytes` from a measured size report (nil when the report was not probed).
    public static func reclaim(from report: SizeReport) -> (bytes: Int64?, estimate: Bool) {
        guard let p = report.privateBytes else { return (nil, false) }
        return (max(0, min(p, report.allocatedBytes)), report.privateIsEstimate)
    }

    /// "<ruleID>|<lexically normalized absolute path>"
    public static func makeID(ruleID: String, url: URL) -> ID {
        "\(ruleID)|\(PathNormalization.lexical(url.absoluteURL.path))"
    }

    public var path: String { url.path }

    /// `tier.isSelectable && cleanupMethod.isActionable`
    public var isSelectable: Bool { tier.isSelectable && cleanupMethod.isActionable }

    /// Selectable, Safe, and not in a never-bulk category (model weights, personal files, apps…).
    public var isBulkSelectable: Bool {
        isSelectable && tier.isBulkSelectable && !category.isNeverBulkSelectable
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, path, displayName, tool, category, project, sizeAllocated, sizeLogical
        case fileCount, lastModified, tier, explanation, ruleID, cleanup, requiresAppQuit, flags, groupID, inUseBy, inUsePID
        case reclaimableBytes, reclaimIsEstimate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let path = try c.decode(String.self, forKey: .path)
        guard path.hasPrefix("/") else {
            throw DecodingError.dataCorruptedError(
                forKey: .path, in: c, debugDescription: "Path must be absolute")
        }
        let allocated = try c.decode(Int64.self, forKey: .sizeAllocated)
        let logical = try c.decode(Int64.self, forKey: .sizeLogical)
        let count = try c.decode(Int.self, forKey: .fileCount)
        guard allocated >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .sizeAllocated, in: c, debugDescription: "Negative size")
        }
        guard logical >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .sizeLogical, in: c, debugDescription: "Negative size")
        }
        guard count >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .fileCount, in: c, debugDescription: "Negative file count")
        }
        let flagStrings = try c.decodeIfPresent([String].self, forKey: .flags) ?? []
        self.init(
            id: try c.decode(String.self, forKey: .id),
            url: URL(fileURLWithPath: path),
            displayName: try c.decode(String.self, forKey: .displayName),
            tool: try c.decode(ToolID.self, forKey: .tool),
            category: try c.decode(ItemCategory.self, forKey: .category),
            project: try c.decodeIfPresent(ProjectRef.self, forKey: .project),
            sizeAllocated: allocated,
            sizeLogical: logical,
            fileCount: count,
            lastModified: try c.decodeIfPresent(Date.self, forKey: .lastModified),
            tier: try c.decode(RiskTier.self, forKey: .tier),
            explanation: try c.decode(String.self, forKey: .explanation),
            ruleID: try c.decode(String.self, forKey: .ruleID),
            cleanupMethod: try c.decode(CleanupMethod.self, forKey: .cleanup),
            requiresAppQuit: try c.decodeIfPresent(String.self, forKey: .requiresAppQuit),
            flags: Set(flagStrings.compactMap(ItemFlag.init(rawValue:))),
            groupID: try c.decodeIfPresent(String.self, forKey: .groupID),
            inUseBy: try c.decodeIfPresent(String.self, forKey: .inUseBy),
            inUsePID: try c.decodeIfPresent(Int32.self, forKey: .inUsePID),
            reclaimableBytes: try c.decodeIfPresent(Int64.self, forKey: .reclaimableBytes),
            reclaimIsEstimate: try c.decodeIfPresent(Bool.self, forKey: .reclaimIsEstimate) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url.path, forKey: .path)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(tool, forKey: .tool)
        try c.encode(category, forKey: .category)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encode(sizeAllocated, forKey: .sizeAllocated)
        try c.encode(sizeLogical, forKey: .sizeLogical)
        try c.encode(fileCount, forKey: .fileCount)
        try c.encodeIfPresent(lastModified, forKey: .lastModified)
        try c.encode(tier, forKey: .tier)
        try c.encode(explanation, forKey: .explanation)
        try c.encode(ruleID, forKey: .ruleID)
        try c.encode(cleanupMethod, forKey: .cleanup)
        try c.encodeIfPresent(requiresAppQuit, forKey: .requiresAppQuit)
        try c.encode(flags.map(\.rawValue).sorted(), forKey: .flags)
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encodeIfPresent(inUseBy, forKey: .inUseBy)
        try c.encodeIfPresent(inUsePID, forKey: .inUsePID)
        try c.encodeIfPresent(reclaimableBytes, forKey: .reclaimableBytes)
        if reclaimIsEstimate { try c.encode(true, forKey: .reclaimIsEstimate) }
    }
}
