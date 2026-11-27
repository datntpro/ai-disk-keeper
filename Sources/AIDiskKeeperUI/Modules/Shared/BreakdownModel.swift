import DiskKeeperCore
import Foundation

/// One bar of a breakdown chart: bytes per tier for a tool or a project.
struct BreakdownRow: Identifiable, Equatable {
    /// Filter value (`ToolID.rawValue` / resolved project id / `ItemQuery.noProject`); nil for the "Other" bucket.
    let id: String?
    let name: String
    var safe: Int64 = 0
    var review: Int64 = 0
    var keep: Int64 = 0
    var total: Int64 { safe + review + keep }
    var chartID: String { id ?? "\u{0}other" }

    mutating func add(_ item: ScanItem) {
        switch item.tier {
        case .safe: safe += item.sizeAllocated
        case .review: review += item.sizeAllocated
        case .keep: keep += item.sizeAllocated
        }
    }

    func bytes(for tier: RiskTier) -> Int64 {
        switch tier {
        case .safe: safe
        case .review: review
        case .keep: keep
        }
    }

    /// "Name, 1.2 GB, 300 MB safe"
    var accessibilityLabel: String { BreakdownCopy.a11y(name: name, total: total, safe: safe) }
}

enum ProjectBreakdown {
    /// The project filter key of an item: resolved repo-root id, or `ItemQuery.noProject`.
    static func projectID(of item: ScanItem) -> String {
        item.project.map { ProjectKeyResolver.shared.repoRoot(for: $0).id } ?? ItemQuery.noProject
    }

    static func byTool(_ items: [ScanItem], limit: Int = 8) -> [BreakdownRow] {
        rows(items, limit: limit) { item in (item.tool.rawValue, item.tool.uiName) }
    }

    static func byProject(_ items: [ScanItem], limit: Int = 8) -> [BreakdownRow] {
        var names: [String: String] = [:]
        return rows(items, limit: limit) { item in
            guard let project = item.project else { return (ItemQuery.noProject, BreakdownCopy.noProject) }
            let root = ProjectKeyResolver.shared.repoRoot(for: project)
            names[root.id] = root.displayName
            return (root.id, root.displayName)
        }
    }

    /// Top `limit` by total bytes (ties by name), the rest folded into one "Other" row. Sums always equal the input.
    static func rows(_ items: [ScanItem], limit: Int, key: (ScanItem) -> (id: String, name: String)) -> [BreakdownRow] {
        var byID: [String: BreakdownRow] = [:]
        for item in items {
            let (id, name) = key(item)
            var row = byID[id] ?? BreakdownRow(id: id, name: name)
            row.add(item)
            byID[id] = row
        }
        let sorted = byID.values.sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
        guard sorted.count > limit else { return sorted }
        var other = BreakdownRow(id: nil, name: BreakdownCopy.other)
        for r in sorted.dropFirst(limit) { other.safe += r.safe; other.review += r.review; other.keep += r.keep }
        return Array(sorted.prefix(limit)) + [other]
    }
}
