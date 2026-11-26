import DiskKeeperCore
import SwiftUI

/// The inspected copy: full path, dates, git, other names, clone status in words, and why it is listed.
struct DuplicatesInspector: View {
    let model: DuplicatesModel

    var body: some View {
        if let path = model.inspectedPath, let group = model.group(containing: path),
           let member = group.members.first(where: { $0.path == path }) {
            ScrollView {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
                    Text((member.path as NSString).lastPathComponent).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if model.isKeeper(member, in: group) { StatusPill(kind: .keeps) }
                    Text(DuplicatesCopy.explanation(for: member, in: group)).font(.callout).foregroundStyle(.secondary)
                    field(loc("dup.inspector.path", "Path")) { Text(member.path).font(ADKTheme.Font.path).textSelection(.enabled) }
                    field(loc("detail.size", "Size")) {
                        Text(Formatting.bytes(member.allocatedBytes))
                        Text(loc("dup.inspector.logical", "\(Formatting.bytes(member.logicalBytes)) apparent")).font(.caption).foregroundStyle(.secondary)
                    }
                    field(loc("dup.inspector.dates", "Dates")) {
                        Text(loc("dup.inspector.created", "Created \(Formatting.absolute(member.created))"))
                        Text(loc("dup.inspector.modified", "Modified \(Formatting.absolute(member.modified))"))
                    }
                    if member.isInGitRepo {
                        Label(loc("dup.keeper.git", "in a git repo"), systemImage: "arrow.triangle.branch").font(.callout)
                    }
                    if !member.otherLinkPaths.isEmpty {
                        field(loc("dup.inspector.links", "Other names (hard links)")) {
                            ForEach(member.otherLinkPaths, id: \.self) { Text($0).font(ADKTheme.Font.path).textSelection(.enabled) }
                        }
                    }
                    field(loc("dup.inspector.storage", "Storage")) { Text(storageText(member)) }
                    Button { FinderReveal.reveal(URL(fileURLWithPath: member.path)) } label: {
                        Label(loc("action.reveal", "Reveal in Finder"), systemImage: "folder")
                    }
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(loc("dup.inspector.empty", "Select a copy to see why it's listed.")).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func storageText(_ m: DuplicateMember) -> String {
        if m.sharesAllStorage { return loc("dup.storage.all", "All of its storage is shared with another file (APFS clone or hard link). Deleting it frees nothing.") }
        if m.sharesStorage { return loc("dup.storage.partial", "Some storage is shared or unknown, so deleting it may free less than its size.") }
        return loc("dup.storage.own", "Its own storage: deleting it frees its full size.")
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            content()
        }
    }
}
