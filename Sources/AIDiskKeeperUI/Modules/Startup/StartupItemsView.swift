import DiskKeeperCore
import SwiftUI

struct StartupItemsView: View {
    @Bindable var model: StartupItemsModel
    let coordinator: CleanupCoordinator

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text(StartupCopy.title).font(.headline)
                Text(StartupCopy.subtitle).font(.caption).foregroundStyle(.adkText3)
            }
            Spacer()
            Button { Task { await model.refresh() } } label: { Label(StartupCopy.refresh, systemImage: "arrow.clockwise") }
                .disabled(model.phase == .loading)
            Button(StartupCopy.openLoginItems) { model.openLoginItemsSettings() }
        }
        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.md)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            StateView(kind: .progress(nil), symbol: "power.circle", title: StartupCopy.title, message: StartupCopy.loading)
        case .failed(let reason):
            StateView(kind: .blockingError, symbol: "exclamationmark.triangle", title: StartupCopy.failedTitle,
                      message: StateCopy.errorStartup + "\n" + reason,
                      actions: [StateAction(title: StartupCopy.refresh) { Task { await model.refresh() } }])
        case .ready:
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
                    cards
                    if model.loadStateUnavailable {
                        Label(StartupCopy.loadStateWarning, systemImage: "info.circle").font(.caption).foregroundStyle(.adkText2)
                    }
                }
                .padding(ADKTheme.Spacing.lg)
                if model.rows.isEmpty { emptyState } else { table }
                footer
            }
        }
    }

    private var cards: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            card(.user, title: StartupCopy.cardUser, count: model.userCount, note: "~/Library/LaunchAgents")
            card(.system, title: StartupCopy.cardSystem, count: model.systemCount, note: StartupCopy.cardSystemNote)
            card(.broken, title: StartupCopy.cardBroken, count: model.brokenCount, note: StartupCopy.cardBrokenNote)
        }
    }

    private func card(_ filter: StartupItemsModel.Filter, title: String, count: Int, note: String) -> some View {
        let selected = model.filter == filter
        return Button { model.filter = selected ? .all : filter } label: {
            SectionCard {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout).foregroundStyle(.adkText2)
                    Text(StartupCopy.countLabel(count)).font(.title.weight(.semibold)).foregroundStyle(.adkText)
                    Text(note).font(.caption).foregroundStyle(.adkText3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay { if selected { RoundedRectangle(cornerRadius: ADKTheme.Radius.lg).strokeBorder(.adkAccent, lineWidth: 2) } }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var table: some View {
        Table(model.rows, selection: $model.inspectedID, sortOrder: $model.sortOrder) {
            TableColumn(Text(verbatim: "")) { item in
                SelectionCheckbox(item: model.scanItem(for: item), selection: model.selection)
            }
            .width(28)
            TableColumn(StartupCopy.colItem, sortUsing: StartupItemComparator(column: .item)) { item in
                StartupItemCell(item: item)
                    .accessibilityLabel(StartupCopy.rowA11y(item))
            }
            TableColumn(StartupCopy.colWhere) { item in StartupDomainPill(domain: item.domain) }
                .width(min: 110, ideal: 130)
            TableColumn(StartupCopy.colRuns) { item in
                Text(StartupCopy.runs(item)).foregroundStyle(.adkText2).lineLimit(2)
            }
            .width(min: 100, ideal: 150)
            TableColumn(StartupCopy.colStatus, sortUsing: StartupItemComparator(column: .status)) { item in
                StartupStatusCell(item: item, model: model)
            }
            .width(min: 200, ideal: 300)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let item = model.items.first(where: { $0.id == id }) {
                Button(StartupCopy.revealPlist) { model.revealPlist(item) }
                if item.programState == .present { Button(StartupCopy.revealProgram) { model.revealProgram(item) } }
                if item.label != nil { Button(StartupCopy.copyLabel) { model.copyLabel(item) } }
            }
        }
    }

    private var emptyState: some View {
        StateView(kind: .empty, symbol: "power.circle", title: StartupCopy.emptyTitle,
                  message: model.filter == .broken ? StartupCopy.emptyBroken : StartupCopy.emptyNone,
                  actions: model.filter == .all ? [] : [StateAction(title: loc("startup.action.showAll", "Show all")) { model.filter = .all }])
    }

    private var footer: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            Text(StartupCopy.footerNote).font(.callout).foregroundStyle(.adkText3).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(StartupCopy.review) { model.review(using: coordinator) }
                .buttonStyle(.borderedProminent).tint(.adkAccent)
                .disabled(model.selectedItems.isEmpty)
        }
        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.md)
        .adkBarBackground()
        .overlay(alignment: .top) { Rectangle().fill(.adkLine).frame(height: ADKTheme.hairline) }
        .accessibilityElement(children: .contain)
    }
}
