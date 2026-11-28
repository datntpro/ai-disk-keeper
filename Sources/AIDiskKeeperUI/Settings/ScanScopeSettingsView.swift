import DiskKeeperCore
import SwiftUI
import UniformTypeIdentifiers

struct ScanScopeSettingsView: View {
    let model: SettingsModel
    @State private var importing: Target?
    private enum Target { case excluded, project }

    var body: some View {
        Form {
            list(loc("settings.scope.excluded.title", "Excluded folders"), paths: model.settings.excludedPaths, kind: loc("settings.scope.excluded.kind", "excluded folder"),
                 help: loc("settings.scope.excluded.help", "Anything inside these folders, and any item that contains them, is never shown or cleaned."),
                 add: { importing = .excluded }, remove: model.removeExcludedPath)
            list(loc("settings.scope.projects.title", "Project folders"), paths: model.settings.projectRoots, kind: loc("settings.scope.projects.kind", "project folder"),
                 help: loc("settings.scope.projects.help", "Where AI Disk Keeper looks for projects and worktrees (used by worktree and build-artifact scanning)."),
                 add: { importing = .project }, remove: model.removeProjectRoot)
            WorktreeSettingsSection(model: model)
            HStack {
                Button(loc("settings.scope.reset", "Reset to defaults")) { model.resetScopeToDefaults() }
                Spacer()
                Text(loc("settings.changesApplyNextScan", "Changes apply to the next scan.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: [.folder]) { result in
            let target = importing
            importing = nil
            guard case .success(let url) = result else { return }
            if target == .excluded { model.addExcludedPath(url) } else { model.addProjectRoot(url) }
        }
    }

    private func list(_ title: String, paths: [String], kind: String, help: String,
                      add: @escaping () -> Void, remove: @escaping (String) -> Void) -> some View {
        Section {
            List(paths, id: \.self) { path in
                HStack {
                    Text(path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { remove(path) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(loc("settings.scope.remove.a11y", "Remove \(kind) \(path)"))
                }
            }
            .frame(minHeight: 70)
            HStack {
                Button(action: add) { Image(systemName: "plus") }.accessibilityLabel(loc("settings.scope.add.a11y", "Add \(kind)"))
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text(title).font(.headline) }
    }
}

/// Idle threshold and the GitHub CLI opt-in for the worktree inventory.
struct WorktreeSettingsSection: View {
    let model: SettingsModel
    @State private var consent: GitHubConsentModel?

    var body: some View {
        Section {
            // LabeledContent with an empty label puts the rows in the same column as the section header and the
            // other sections' lists (bare rows land in the Form's label column, left of the header).
            LabeledContent {
              VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(WorktreeCopy.settingsIdle).frame(maxWidth: .infinity, alignment: .leading)
                    Text(WorktreeCopy.hours(model.settings.worktreeIdleHours)).monospacedDigit().foregroundStyle(.secondary)
                    Stepper(value: Binding(get: { model.settings.worktreeIdleHours }, set: { model.setWorktreeIdleHours($0) }),
                            in: AppSettings.worktreeIdleHoursRange) { EmptyView() }
                        .labelsHidden()
                }
                Text(WorktreeCopy.settingsIdleHelp).font(.caption).foregroundStyle(.secondary)
                if let consent {
                    GitHubCLIToggle(consent: consent)
                    Text(WorktreeCopy.ghToggleHelp).font(.caption).foregroundStyle(.secondary)
                        .sheet(isPresented: Bindable(consent).isSheetShown) { GitHubConsentSheet(consent: consent) }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            } label: { EmptyView() }
        } header: { Text(WorktreeCopy.settingsTitle).font(.headline) }
        .onAppear {
            guard consent == nil else { return }
            let settings = model
            consent = GitHubConsentModel(isOn: { settings.settings.useGitHubCLIForPRs }, store: .defaults(),
                                         apply: { settings.setUseGitHubCLIForPRs($0) })
        }
    }
}
