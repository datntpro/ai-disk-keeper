import DiskKeeperCore
import SwiftUI

/// Duplicates: groups of byte-identical files. One copy per group is always kept, and the screen says which.
struct DuplicatesView: View {
    /// What the pane shows. A pure function of the model state, so it is unit-tested.
    enum Content: Equatable { case needsIndex, progress, failed(String), empty, stoppedEmpty, list }

    static func content(phase: DuplicatesModel.Phase, hasTree: Bool, hasGroups: Bool) -> Content {
        guard hasTree else { return .needsIndex }
        switch phase {
        case .needsIndex, .hashing: return .progress
        case .failed(let reason): return .failed(reason)
        case .ready: return hasGroups ? .list : .empty
        case .cancelled: return hasGroups ? .list : .stoppedEmpty
        }
    }

    let model: DuplicatesModel
    let index: DiskIndexModel
    let cleanup: CleanupCoordinator

    var body: some View {
        IndexGateView(index: index) { _ in screen }
            .task(id: index.generation) { model.refreshIfNeeded() }
            .onChange(of: index.tree == nil) { _, _ in model.refreshIfNeeded() }
    }

    private var screen: some View {
        let kind = Self.content(phase: model.phase, hasTree: index.tree != nil, hasGroups: !model.groups.isEmpty)
        return VStack(spacing: 0) {
            header
            switch kind {
            case .needsIndex, .progress: progressView
            case .failed(let reason):
                StateView(kind: .error, symbol: "exclamationmark.triangle", title: loc("dup.failed.title", "Couldn't compare files"),
                          message: reason, actions: [StateAction(title: loc("dup.recheck", "Re-check")) { model.analyse() }])
            case .empty:
                StateView(kind: .empty, symbol: "checkmark.circle", title: loc("dup.empty.title", "No duplicates found"),
                          message: loc("dup.empty.body", "No identical files of \(Formatting.bytes(model.minimumBytes)) or more in your Home folder."))
            case .stoppedEmpty:
                StateView(kind: .empty, symbol: "stop.circle", title: loc("dup.stopped", "Stopped — results may be incomplete"),
                          message: "", actions: [StateAction(title: loc("dup.recheck", "Re-check")) { model.analyse() }])
            case .list:
                list
                DuplicatesActionBar(model: model) { model.reviewCleanup(using: cleanup) }
            }
        }
    }

    private var progressView: some View {
        var message = loc("dup.progress.start", "Looking for identical files…")
        if case .hashing(let stats?) = model.phase {
            message = DuplicatesCopy.progress(done: stats.partialHashed + stats.fullHashed, total: stats.candidates)
        }
        return StateView(kind: .progress(nil), symbol: "doc.on.doc", title: loc("module.duplicates", "Duplicates"), message: message,
                         actions: [StateAction(title: loc("action.stop", "Stop")) { model.cancel() }])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: ADKTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("dup.title", "Duplicates")).font(ADKTheme.Font.largeTitle).accessibilityAddTraits(.isHeader)
                    if !model.groups.isEmpty {
                        Text(DuplicatesCopy.subtitle(groups: model.groups.count, bytes: model.totalSavings))
                            .font(.callout).foregroundStyle(.adkText2)
                    }
                }
                Spacer()
                if model.phase == .cancelled, !model.groups.isEmpty {
                    ReasonChip(text: loc("dup.stopped", "Stopped — results may be incomplete"))
                }
                Menu {
                    ForEach(DuplicatesModel.thresholds, id: \.self) { t in
                        Button { model.minimumBytes = t } label: {
                            if t == model.minimumBytes { Label(DuplicatesCopy.threshold(t), systemImage: "checkmark") }
                            else { Text(DuplicatesCopy.threshold(t)) }
                        }
                    }
                } label: { Text(DuplicatesCopy.threshold(model.minimumBytes)) }
                    .fixedSize()
                Button(loc("dup.recheck", "Re-check")) { model.analyse() }
                    .disabled({ if case .hashing = model.phase { return true } else { return false } }())
            }
            noticeCard
        }
        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.top, ADKTheme.Spacing.lg).padding(.bottom, ADKTheme.Spacing.md)
    }

    private var noticeCard: some View {
        SectionCard(padding: ADKTheme.Spacing.md) {
            Label(loc("dup.notice", "One copy in every group is always kept. Copies that are APFS clones or hard links share storage, so removing them frees nothing — they're listed but not counted."),
                  systemImage: "info.circle")
                .font(.callout).foregroundStyle(.adkText2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var list: some View {
        List(selection: Binding(get: { model.inspectedPath }, set: { model.inspectedPath = $0 })) {
            ForEach(model.groups) { group in
                DuplicateGroupSection(model: model, group: group)
            }
        }
        .listStyle(.inset)
        .onKeyPress(.space) {
            guard let path = model.inspectedPath else { return .ignored }
            let refused = model.refusedKeeperCount
            model.toggle(path: path)
            if model.refusedKeeperCount != refused {
                AccessibilityNotification.Announcement(loc("dup.a11y.keeperRefused", "The kept copy can't be selected")).post()
            }
            return .handled
        }
    }
}

/// Bottom bar: honest savings, the keep rule, and the one action. Mirrors `SelectionActionBar`, plus the rule picker.
struct DuplicatesActionBar: View {
    let model: DuplicatesModel
    let review: () -> Void

    var body: some View {
        let savings = model.selectedSavings
        let count = model.selectedCount
        VStack(spacing: 0) {
            HStack(spacing: ADKTheme.Spacing.md) {
                SizeText(savings.certainBytes, qualifier: .upTo).font(.headline)
                Text(DuplicatesCopy.selectedCount(count)).foregroundStyle(.adkText2).lineLimit(1)
                Spacer()
                Picker(loc("dup.rule.label", "Keep rule:"), selection: Binding(get: { model.rule }, set: { model.rule = $0 })) {
                    ForEach(KeeperRule.allCases, id: \.self) { Text(DuplicatesCopy.ruleName($0)).tag($0) }
                }
                .pickerStyle(.menu).fixedSize()
                Button(loc("dup.action.review", "Review cleanup…"), action: review)
                    .buttonStyle(.borderedProminent).tint(.adkAccent).disabled(count == 0)
            }
            if savings.mayFreeLess, count > 0 {
                Text(loc("dup.mayFreeLess", "Some copies may free less (shared or unknown storage)"))
                    .font(.caption).foregroundStyle(.adkText3)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
            }
        }
        .font(.callout)
        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.md)
        .adkBarBackground()
        .overlay(alignment: .top) { Rectangle().fill(.adkLine).frame(height: ADKTheme.hairline) }
        .accessibilityElement(children: .contain)
    }
}
