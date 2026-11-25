import DiskKeeperCore
import SwiftUI

struct ItemDetailView: View {
    let item: ScanItem?

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.displayName).font(.title2.weight(.semibold)).textSelection(.enabled)
                    let s = TierStyle.style(for: item.tier)
                    TierBadge(tier: item.tier)
                    if let id = item.requiresAppQuit { QuitAppNote(bundleID: id) }
                    Text(s.longExplanation).font(.callout).foregroundStyle(.secondary)
                    section(loc("detail.why", "Why this tier")) { Text(item.explanation) }
                    section(loc("detail.size", "Size")) {
                        Text(Formatting.bytes(item.sizeAllocated)).font(.title3)
                        Text(loc("detail.sizeDetail", "\(Formatting.bytes(item.sizeLogical)) apparent · \(item.fileCount) files · modified \(Formatting.absolute(item.lastModified))"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    section(loc("detail.where", "Where")) {
                        Text("\(item.tool.uiName) · \(item.category.displayName)")
                        if let p = item.project { Text(loc("detail.project", "Project: \(p.displayName)")) }
                        Text(loc("detail.rule", "Rule: \(item.ruleID)")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(item.path).font(.callout.monospaced()).textSelection(.enabled)
                        Button { FinderReveal.reveal(item.url) } label: { Label(loc("action.reveal", "Reveal in Finder"), systemImage: "folder") }
                            .disabled(!FinderReveal.exists(item.url))
                    }
                    let notes = flagNotes(item)
                    if !notes.isEmpty {
                        section(loc("detail.notes", "Notes")) { ForEach(notes, id: \.self) { Label($0, systemImage: "info.circle").font(.callout) } }
                    }
                    section(loc("detail.cleanup", "Cleanup")) { Text(cleanupText(item.cleanupMethod)) }
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(loc("detail.empty", "Select an item to see why it's here.")).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func flagNotes(_ item: ScanItem) -> [String] {
        var out: [String] = []
        if item.flags.contains(.sizeIncomplete) { out.append(loc("note.sizeIncomplete", "Some files couldn't be read, so the real size may be larger.")) }
        if item.flags.contains(.needsFullDiskAccess) { out.append(loc("note.needsFDA", "macOS blocked access to part of this folder.")) }
        if item.flags.contains(.inUse) { out.append(loc("note.inUse", "In use by a running app.")) }
        return out
    }

    func cleanupText(_ m: CleanupMethod) -> String {
        m.isActionable ? loc("cleanup.trash", "Moves to Trash") : loc("cleanup.reportOnly", "Report only: no cleanup action")
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
        }
    }
}
