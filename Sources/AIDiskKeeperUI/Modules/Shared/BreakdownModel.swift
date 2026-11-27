import DiskKeeperCore
import Foundation

/// One bar of a breakdown chart: bytes per tier for a tool or a project.
struct BreakdownRow: Identifiable, Equatable {
    init(id: String?, name: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.label = name
    }

    /// Filter value (`ToolID.rawValue` / resolved project id / `ItemQuery.noProject`); nil for the "Other" bucket.
    let id: String?
    let name: String
    /// Extra context to tell same-named rows apart (a project's parent folder).
    var detail: String?
    /// What the axis and VoiceOver show: `name`, or `name (detail)` when another row has the same name.
    var label: String
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
    var accessibilityLabel: String { BreakdownCopy.a11y(name: label, total: total, safe: safe) }
}

enum ProjectBreakdown {
    /// The project filter key of an item: resolved repo-root id, or `ItemQuery.noProject`.
    static func projectID(of item: ScanItem) -> String {
        item.project.map { ProjectKeyResolver.shared.repoRoot(for: $0).id } ?? ItemQuery.noProject
    }

    static func byTool(_ items: [ScanItem], limit: Int = 8) -> [BreakdownRow] {
        rows(items, limit: limit) { item in (item.tool.rawValue, item.tool.uiName, nil) }
    }

    static func byProject(_ items: [ScanItem], limit: Int = 8) -> [BreakdownRow] {
        rows(items, limit: limit) { item in
            guard let project = item.project else { return (ItemQuery.noProject, BreakdownCopy.noProject, nil) }
            let root = ProjectKeyResolver.shared.repoRoot(for: project)
            return (root.id, root.displayName, parentFolder(of: root.id))
        }
    }

    /// Last component of the folder that contains `path`; nil for `name:` ids and top-level paths.
    static func parentFolder(of path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent.isEmpty || parent == "/" ? nil : parent
    }

    /// Top `limit` by total bytes (ties by name), the rest folded into one "Other" row. Sums always equal the input.
    static func rows(_ items: [ScanItem], limit: Int, key: (ScanItem) -> (id: String, name: String, detail: String?)) -> [BreakdownRow] {
        var byID: [String: BreakdownRow] = [:]
        for item in items {
            let (id, name, detail) = key(item)
            var row = byID[id] ?? BreakdownRow(id: id, name: name, detail: detail)
            row.add(item)
            byID[id] = row
        }
        let sorted = byID.values.sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
        var out = Array(sorted.prefix(limit))
        if sorted.count > limit {
            var other = BreakdownRow(id: nil, name: BreakdownCopy.other)
            for r in sorted.dropFirst(limit) { other.safe += r.safe; other.review += r.review; other.keep += r.keep }
            out.append(other)
        }
        return disambiguated(out)
    }

    /// Same-named rows get `name (detail)`; with no detail to add they fall back to the id so labels stay unique.
    static func disambiguated(_ rows: [BreakdownRow]) -> [BreakdownRow] {
        var counts: [String: Int] = [:]
        for r in rows { counts[r.name, default: 0] += 1 }
        var out = rows
        for i in out.indices where counts[out[i].name, default: 0] > 1 {
            out[i].label = BreakdownCopy.disambiguated(out[i].name, out[i].detail ?? out[i].id ?? "")
        }
        return out
    }
}
