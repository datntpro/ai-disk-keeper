import DiskKeeperCore
import SwiftUI

/// "Build the index first" for Map, Large & Old and Duplicates. Shows `content` as soon as a tree exists
/// (also while re-indexing). Never starts a build by itself: the user clicks, after reading what macOS may ask.
struct IndexGateView<Content: View>: View {
    let index: DiskIndexModel
    @ViewBuilder var content: (DiskTree) -> Content

    var body: some View {
        if let tree = index.tree {
            content(tree)
        } else if index.phase == .indexing {
            StateView(kind: .progress(nil), symbol: "internaldrive", title: loc("index.gate.title", "Map your disk"),
                      message: progressText,
                      actions: [StateAction(title: loc("action.stop", "Stop")) { index.cancel() }])
        } else {
            StateView(kind: .empty, symbol: "internaldrive", title: loc("index.gate.title", "Map your disk"),
                      message: gateMessage, actions: startActions)
        }
    }

    private var progressText: String {
        let p = index.progress
        return loc("index.progress", "Reading folder sizes… \(Formatting.count(p?.entriesVisited ?? 0)) items, \(Formatting.bytes(p?.allocatedBytesSoFar ?? 0))")
    }

    private var gateMessage: String {
        let intro = loc("index.gate.message", "AI Disk Keeper reads folder sizes only, never file contents. macOS may ask for access to Desktop, Documents and Downloads; if you decline, those folders are shown as locked.")
        if case .failed(let reason) = index.phase {
            return loc("index.failed", "Couldn't map the disk: \(reason)") + "\n\n" + intro
        }
        return intro
    }

    private var startActions: [StateAction] {
        var actions = [StateAction(title: loc("index.gate.home", "Map Home folder")) { index.start(.home) }]
        if index.fullDiskAvailable {
            actions.append(StateAction(title: loc("index.gate.fullDisk", "Map whole disk")) { index.start(.fullDisk) })
        } else {
            actions.append(StateAction(title: loc("fda.openPrivacy", "Open Privacy Settings")) {
                NSWorkspace.shared.open(FullDiskAccessCard.privacySettingsURL)
            })
        }
        return actions
    }
}

/// "indexed 3 minutes ago" + Re-index, for the header of every index-backed screen.
struct IndexHeaderView: View {
    let index: DiskIndexModel

    var body: some View {
        HStack(spacing: 8) {
            if index.phase == .indexing { ProgressView().controlSize(.small) }
            if let built = index.builtAt {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(loc("index.builtAgo", "indexed \(Formatting.relative(built))")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(loc("index.reindex", "Re-index")) { index.start(index.scope) }
                .disabled(index.phase == .indexing)
        }
    }
}
