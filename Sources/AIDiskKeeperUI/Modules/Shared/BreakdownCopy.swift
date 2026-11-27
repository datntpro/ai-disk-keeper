import Foundation

enum BreakdownCopy {
    static var byTool: String { loc("breakdown.byTool", "By tool") }
    static var byProject: String { loc("breakdown.byProject", "By project") }
    static var other: String { loc("breakdown.other", "Other") }
    static var noProject: String { loc("breakdown.noProject", "No project") }
    static var clearFilter: String { loc("breakdown.clearFilter", "Clear filter") }
    static func showing(_ name: String) -> String {
        loc("breakdown.showing", "Showing \(name)")
    }
    static func a11y(name: String, total: Int64, safe: Int64) -> String {
        let t = Formatting.bytes(total), s = Formatting.bytes(safe)
        return loc("breakdown.a11y", "\(name), \(t), \(s) safe")
    }
    static var show: String { loc("breakdown.show", "Show breakdown") }
    static var hide: String { loc("breakdown.hide", "Hide breakdown") }
}
