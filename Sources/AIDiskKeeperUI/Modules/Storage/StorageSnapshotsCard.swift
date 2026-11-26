import DiskKeeperCore
import SwiftUI

/// Local APFS snapshots, listed only. There is no delete, thin or "free up" action.
struct StorageSnapshotsCard: View {
    let listing: SnapshotListing
    let openTimeMachine: () -> Void

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
                HStack {
                    Text(loc("storage.snapshots.title", "Local snapshots")).font(.headline)
                    Spacer()
                    if case .listed(let list) = listing, !list.isEmpty {
                        Text(loc("storage.snapshots.count", "\(list.count) snapshots"))
                            .font(.caption).foregroundStyle(.adkText3)
                    }
                }
                switch listing {
                case .listed(let list) where list.isEmpty:
                    Text(loc("storage.snapshots.none", "No local snapshots right now.")).foregroundStyle(.adkText2)
                case .listed(let list):
                    ForEach(list, id: \.name) { snapshot in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text(snapshot.kind.uiName)
                                Spacer()
                                Text(Formatting.absolute(snapshot.date)).foregroundStyle(.adkText2)
                            }
                            PathText(snapshot.name)
                        }
                        .accessibilityElement(children: .combine)
                    }
                case .unavailable(let reason):
                    Text(reason.uiMessage).foregroundStyle(.adkText2)
                }
                Text(StorageExplanation.snapshots.uiText).font(.caption).foregroundStyle(.adkText3)
                Button(loc("storage.snapshots.openTM", "Open Time Machine settings"), action: openTimeMachine)
                    .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
