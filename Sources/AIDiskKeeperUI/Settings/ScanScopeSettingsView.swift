import SwiftUI
import UniformTypeIdentifiers

struct ScanScopeSettingsView: View {
    let model: SettingsModel
    @State private var importing: Target?
    private enum Target { case excluded, project }

    var body: some View {
        Form {
            list("Excluded folders", paths: model.settings.excludedPaths, kind: "excluded folder",
                 help: "Anything inside these folders, and any item that contains them, is never shown or cleaned.",
                 add: { importing = .excluded }, remove: model.removeExcludedPath)
            list("Project folders", paths: model.settings.projectRoots, kind: "project folder",
                 help: "Where AI Disk Keeper looks for projects and worktrees (used by worktree and build-artifact scanning).",
                 add: { importing = .project }, remove: model.removeProjectRoot)
            HStack {
                Button("Reset to defaults") { model.resetScopeToDefaults() }
                Spacer()
                Text("Changes apply to the next scan.").font(.caption).foregroundStyle(.secondary)
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
                        .accessibilityLabel("Remove \(kind) \(path)")
                }
            }
            .frame(minHeight: 70)
            HStack {
                Button(action: add) { Image(systemName: "plus") }.accessibilityLabel("Add \(kind)")
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text(title).font(.headline) }
    }
}
