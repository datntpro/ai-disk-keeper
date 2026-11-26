import DiskKeeperCore
import SwiftUI

/// The Trash size, or why it can't be measured. "Open Trash" shows Finder's Trash; this screen never empties it.
struct StorageTrashCard: View {
    let trash: TrashInfo
    let openTrash: () -> Void
    let grantAccess: () -> Void

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
                Text(loc("storage.trash.title", "Trash")).font(.headline)
                if let message = trash.state.uiMessage {
                    Text(message).foregroundStyle(.adkText2)
                } else if let bytes = trash.allocatedBytes {
                    Text(loc("storage.trash.size", "\(Formatting.bytes(bytes)) · \(Formatting.count(trash.itemCount ?? 0)) items"))
                        .monospacedDigit()
                }
                HStack {
                    Button(loc("storage.trash.open", "Open Trash"), action: openTrash)
                    if case .needsFullDiskAccess = trash.state {
                        Button(loc("storage.trash.grantFDA", "Grant Full Disk Access…"), action: grantAccess)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
