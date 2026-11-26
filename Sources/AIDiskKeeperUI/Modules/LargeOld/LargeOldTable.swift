import AppKit
import DiskKeeperCore
import SwiftUI

struct LargeOldTable: View {
    @Bindable var model: LargeOldModel

    var body: some View {
        let now = model.currentTime
        Table(model.rows, selection: $model.inspectedPath, sortOrder: $model.sortOrder) {
            TableColumn(Text(verbatim: "")) { f in
                SelectionCheckbox(item: model.item(for: f), selection: model.selection)
            }
            .width(28)
            TableColumn(LargeOldCopy.column(.file), sortUsing: LargeFileComparator(column: .name)) { f in fileCell(f) }
            TableColumn(LargeOldCopy.column(.kind), sortUsing: LargeFileComparator(column: .kind)) { f in
                Text(LargeOldCopy.kindOne(f.kind)).foregroundStyle(.adkText2)
            }
            .width(min: 90, ideal: 130)
            TableColumn(LargeOldCopy.column(.lastOpened), sortUsing: LargeFileComparator(column: .lastOpened)) { f in
                HStack(spacing: 4) {
                    Text(LargeOldCopy.lastOpened(f, now: now))
                    Image(systemName: LargeOldCopy.sourceSymbol(f.lastOpenedSource)).font(.caption2)
                }
                .foregroundStyle(.adkText2)
                .help(LargeOldCopy.sourceLabel(f.lastOpenedSource))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(LargeOldCopy.lastOpenedA11y(f, now: now))
            }
            .width(min: 120, ideal: 160)
            TableColumn(LargeOldCopy.column(.size), sortUsing: LargeFileComparator(column: .size)) { f in
                SizeText(f.allocatedBytes).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            if let path = paths.first, let f = model.rows.first(where: { $0.path == path }) {
                Button(LargeOldCopy.quickLook) { model.quickLook(f) }
                Button(loc("action.reveal", "Reveal in Finder")) { model.reveal(f) }
                Button(LargeOldCopy.copyPath) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(f.path, forType: .string)
                }
            }
        }
        .onKeyPress(.space) { model.handleSpace(); return .handled }
    }

    private func fileCell(_ f: LargeFile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(f.name).lineLimit(1).truncationMode(.middle)
            PathText(f.parentPath)
            if f.installedAppMatch != nil || f.showsSharedStoragePill || f.isMountedImage {
                HStack(spacing: 6) {
                    if let app = f.installedAppMatch {
                        Label(LargeOldCopy.hintInstalled, systemImage: "checkmark.app")
                            .help(LargeOldCopy.installedNamed(app))
                    }
                    if f.isMountedImage {
                        Label(LargeOldCopy.mountedImage, systemImage: "externaldrive.badge.xmark")
                            .foregroundStyle(.adkKeep)
                    }
                    if f.showsSharedStoragePill {
                        Label(LargeOldCopy.shared, systemImage: "externaldrive.connected.to.line.below")
                            .help(LargeOldCopy.sharedHelp)
                    }
                }
                .font(.caption).foregroundStyle(.adkText3)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
