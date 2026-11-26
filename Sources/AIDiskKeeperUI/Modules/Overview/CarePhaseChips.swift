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

    var body: some View {
        let chips = model.visibleChips()
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: ADKTheme.Spacing.sm, alignment: .leading)],
                  alignment: .leading, spacing: ADKTheme.Spacing.sm) {
            ForEach(chips, id: \.self) { module in
                Chip(module: module, state: model.chipState(module), failure: failure(module), reduceMotion: reduceMotion)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OverviewCopy.chipsA11y(chips.map {
            OverviewCopy.chipA11y(OverviewTarget.chipTitle($0), Self.stateWord(model.chipState($0)))
        }.joined(separator: ", ")))
    }

    private func failure(_ module: CareModule) -> String? {
        model.stageFailures[CareScanModel.stage(for: module)]?.uiMessage
    }

    private struct Chip: View {
        let module: CareModule
        let state: CareStageState
        let failure: String?
        let reduceMotion: Bool

        var body: some View {
            HStack(spacing: 5) {
                marker
                Text(OverviewTarget.chipTitle(module)).lineLimit(1)
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
