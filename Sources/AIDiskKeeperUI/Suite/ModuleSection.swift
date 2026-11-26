/// Sidebar sections, top to bottom.
public enum ModuleSection: Int, CaseIterable, Sendable, Hashable {
    case top, storage, aiWorkspace, apps, activity

    /// `nil` for the unnamed top section.
    var title: String? {
        switch self {
        case .top: nil
        case .storage: loc("module.section.storage", "Storage")
        case .aiWorkspace: loc("module.section.aiWorkspace", "AI Workspace")
        case .apps: loc("module.section.apps", "Apps")
        case .activity: loc("module.section.activity", "Activity")
        }
    }
}
