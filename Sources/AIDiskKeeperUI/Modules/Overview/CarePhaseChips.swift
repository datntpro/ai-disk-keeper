import DiskKeeperCore
import SwiftUI

/// One chip per module, lit in the order the scan reaches it. The row is one accessibility element.
struct CarePhaseChips: View {
    let model: CareScanModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func stateWord(_ state: CareStageState) -> String {
        switch state {
        case .pending: OverviewCopy.stagePending
        case .running: OverviewCopy.stageRunning
        case .done: OverviewCopy.stageDone
        case .failed: OverviewCopy.stageFailed
        case .skipped: OverviewCopy.stageSkipped
        }
    }

    /// One drawn chip. The index stage has no module, so it gets its own entry after the rule-stage chips.
    struct Entry: Equatable {
        let title: String
        let state: CareStageState
        let failure: String?
    }

    static func entries(for model: CareScanModel, enabled: Set<ModuleID> = ModuleRegistry.enabledIDs) -> [Entry] {
        let modules = model.visibleChips(enabled: enabled)
        var result = modules.map {
            Entry(title: OverviewTarget.chipTitle($0), state: model.chipState($0),
                  failure: model.stageFailures[CareScanModel.stage(for: $0)]?.uiMessage)
        }
        if model.stages.contains(.index) {
            let state = model.phase == .before ? CareStageState.pending : (model.stageState[.index] ?? .pending)
            let at = modules.lastIndex { CareScanModel.stage(for: $0) == .rules }.map { $0 + 1 } ?? 0
            result.insert(Entry(title: OverviewCopy.chipIndex, state: state,
                                failure: model.stageFailures[.index]?.uiMessage), at: at)
        }
        return result
    }

    var body: some View {
        let chips = Self.entries(for: model)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: ADKTheme.Spacing.sm, alignment: .leading)],
                  alignment: .leading, spacing: ADKTheme.Spacing.sm) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, entry in
                Chip(title: entry.title, state: entry.state, failure: entry.failure, reduceMotion: reduceMotion)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OverviewCopy.chipsA11y(chips.map {
            OverviewCopy.chipA11y($0.title, Self.stateWord($0.state))
        }.joined(separator: ", ")))
    }

    private struct Chip: View {
        let title: String
        let state: CareStageState
        let failure: String?
        let reduceMotion: Bool

        var body: some View {
            HStack(spacing: 5) {
                marker
                Text(title).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(state == .running(nil) || isRunning ? Color.adkAccent : Color.adkText2)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(isRunning ? Color.adkAccentSoft : Color.clear, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.adkLine, lineWidth: ADKTheme.hairline) }
            .help(failure ?? "")
        }

        private var isRunning: Bool { if case .running = state { true } else { false } }

        @ViewBuilder private var marker: some View {
            switch state {
            case .pending: EmptyView()
            case .running:
                if reduceMotion {
                    Circle().fill(Color.adkAccent).frame(width: 6, height: 6)   // a static dot under Reduce Motion
                } else {
                    ProgressView().controlSize(.mini)
                }
            case .done: Image(systemName: "checkmark").font(.caption2.weight(.bold))
            case .failed: Image(systemName: "exclamationmark.circle").font(.caption2.weight(.bold))
            case .skipped: Image(systemName: "minus").font(.caption2.weight(.bold))
            }
        }
    }
}
