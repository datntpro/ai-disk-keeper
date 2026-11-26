import DiskKeeperCore
import SwiftUI

struct LargeOldInspector: View {
    let model: LargeOldModel

    var body: some View {
        if let f = model.inspectedFile {
            let now = model.currentTime
            ScrollView {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
                    Text(f.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    TierBadge(tier: f.isMountedImage ? .keep : .review)
                    Text(f.isMountedImage ? LargeOldCopy.mountedNote : LargeOldCopy.tierNote).font(.callout).foregroundStyle(.adkText2)
                    SectionCard {
                        Text(LargeOldCopy.explanation(f, now: now)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    row(LargeOldCopy.column(.kind), LargeOldCopy.kindOne(f.kind))
                    row(LargeOldCopy.column(.size), Formatting.bytes(f.allocatedBytes))
                    row(LargeOldCopy.sourceLabel(f.lastOpenedSource), Formatting.absolute(f.lastOpened))
                    if let app = f.installedAppMatch { row(LargeOldCopy.hintInstalled, LargeOldCopy.installedNamed(app)) }
                    PathText(f.path)
                    HStack {
                        Button(LargeOldCopy.quickLook) { model.quickLook(f) }
                        Button(loc("action.reveal", "Reveal in Finder")) { model.reveal(f) }
                    }
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(LargeOldCopy.inspectorEmpty).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.adkText3)
            Text(value)
        }
    }
}
