import DiskKeeperCore
import QuickLook
import SwiftUI

struct LargeOldView: View {
    @Bindable var model: LargeOldModel
    let coordinator: CleanupCoordinator
    @State private var showNote = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            IndexGateView(index: model.index) { _ in screen }
        }
        .task(id: model.index.generation) { await model.refresh() }
    }

    private var header: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text(LargeOldCopy.title).font(.headline)
                Text(LargeOldCopy.subtitle).font(.caption).foregroundStyle(.adkText3)
            }
            Spacer()
            TextField(LargeOldCopy.search, text: $model.filters.search)
                .textFieldStyle(.roundedBorder).frame(width: 200)
            IndexHeaderView(index: model.index)
        }
        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.md)
    }

    @ViewBuilder private var screen: some View {
        switch model.phase {
        case .needsIndex, .analysing:
            StateView(kind: .progress(nil), symbol: "doc.badge.clock", title: LargeOldCopy.analysingTitle,
                      message: LargeOldCopy.analysing)
        case .failed(let reason):
            StateView(kind: .error, symbol: "exclamationmark.triangle", title: LargeOldCopy.failedTitle, message: reason)
        case .ready:
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
                    filterBar
                    LargeOldKindSummary(model: model)
                    if model.index.tree?.stats.isComplete == false {
                        Label(LargeOldCopy.incomplete, systemImage: "info.circle").font(.caption).foregroundStyle(.adkText2)
                    }
                }
                .padding(ADKTheme.Spacing.lg)
                if model.rows.isEmpty {
                    emptyState
                } else {
                    LargeOldTable(model: model)
                        .quickLookPreview($model.quickLookURL, in: model.rows.map { URL(fileURLWithPath: $0.path) })
                }
                actionBar
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: ADKTheme.Spacing.sm) {
            Menu(LargeOldCopy.sizeFilter(model.filters.minBytes)) {
                ForEach(SizeThreshold.allCases, id: \.self) { t in
                    Button(LargeOldCopy.sizeFilter(t)) { model.filters.minBytes = t }
                }
            }
            Menu(LargeOldCopy.ageFilter(model.filters.age)) {
                ForEach(AgeThreshold.allCases, id: \.self) { a in
                    Button(LargeOldCopy.ageFilter(a)) { model.filters.age = a }
                }
            }
            Menu(LargeOldCopy.folderFilter(model.folderName)) {
                ForEach(model.folderChoices, id: \.path) { c in
                    Button(c.name) { model.filters.folder = c.path == model.index.tree?.rootPath ? nil : c.path }
                }
            }
            Spacer()
            Label(LargeOldCopy.filterNote, systemImage: "lock").font(.caption).foregroundStyle(.adkText2)
            Button { showNote.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel(LargeOldCopy.filterNote)
                .popover(isPresented: $showNote) {
                    Text(LargeOldCopy.filterNoteMore).padding().frame(width: 280)
                }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyState: some View {
        StateView(kind: .empty, symbol: "doc.badge.clock", title: LargeOldCopy.emptyTitle,
                  message: LargeOldCopy.emptyBody(model.filters.minBytes, model.filters.age),
                  actions: [StateAction(title: LargeOldCopy.showAll) { model.showAllSizes() }])
    }

    private var actionBar: some View {
        let selected = model.selectedItems
        return SelectionActionBar(bytes: model.selectedBytes, countLabel: LargeOldCopy.selectedCount(selected.count),
                                  hint: LargeOldCopy.quickLookHint, primaryTitle: LargeOldCopy.reviewAction,
                                  count: selected.count) { model.reviewCleanup(using: coordinator) }
    }
}
