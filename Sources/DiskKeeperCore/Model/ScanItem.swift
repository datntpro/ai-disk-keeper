import Foundation

/// One cleanable (or report-only) thing found by a scan. Pure data.
public struct ScanItem: Identifiable, Codable, Sendable, Hashable {
    public typealias ID = String

    /// Stable across scans: ``makeID(ruleID:url:)``.
    public let id: ID
    /// File URL, standardized (no "..", no trailing "/"); symlinks NOT resolved.
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
                flags: Set<ItemFlag> = []) {
        precondition(url.isFileURL, "ScanItem requires a file URL")
        let normalized = URL(fileURLWithPath: url.standardizedFileURL.path)
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
    }

    /// "<ruleID>|<standardized absolute path>"
    public static func makeID(ruleID: String, url: URL) -> ID {
        "\(ruleID)|\(url.standardizedFileURL.path)"
    }

    public var path: String { url.path }

    /// `tier.isSelectable && cleanupMethod.isActionable`
    public var isSelectable: Bool { tier.isSelectable && cleanupMethod.isActionable }

    /// Selectable, Safe, and not model weights (models are always per-model review).
    public var isBulkSelectable: Bool {
        isSelectable && tier.isBulkSelectable && category != .modelWeights
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, path, displayName, tool, category, project, sizeAllocated, sizeLogical
        case fileCount, lastModified, tier, explanation, ruleID, cleanup, requiresAppQuit, flags
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
            flags: Set(flagStrings.compactMap(ItemFlag.init(rawValue:)))
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
    }
}
