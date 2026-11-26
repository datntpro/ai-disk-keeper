import DiskKeeperCore
import SwiftUI

/// The Care Scan card: the round primary button, the headline number, one sentence for the state, and the phase chips.
struct CareHero: View {
    enum RingStyle: Equatable { case sweep, `static` }

    let model: CareScanModel
    let storage: StorageModel?
    let showFirstRunNote: Bool
    let onReview: () -> Void
    let onCleanSafe: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Under Reduce Motion there is no sweep: a static ring with the percentage as text.
    static func ringStyle(reduceMotion: Bool) -> RingStyle { reduceMotion ? .static : .sweep }

    private var eyebrow: String {
        switch model.phase {
        case .before: OverviewCopy.eyebrowBefore
        case .scanning: OverviewCopy.eyebrowScanning
        case .results, .stopped: OverviewCopy.eyebrowResults
        }
    }

    private var headline: String {
        switch model.phase {
        case .before: storage?.freeBytes.map { OverviewCopy.free(Formatting.bytes($0)) } ?? OverviewCopy.eyebrowBefore
        case .scanning: OverviewCopy.found(Formatting.bytes(model.foundBytes))
        case .results, .stopped: Formatting.bytes(model.reviewableBytes)
        }
    }

    /// The number the headline animates on.
    private var headlineValue: Int64 {
        switch model.phase {
        case .before: storage?.freeBytes ?? 0
        case .scanning: model.foundBytes
        case .results, .stopped: model.reviewableBytes
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .before: OverviewCopy.subtitleBefore
        case .scanning:
            OverviewCopy.subtitleScanning(model.stages.first { if case .running = model.stageState[$0] { true } else { false } }
                .map(Self.stageName) ?? OverviewCopy.eyebrowBefore)
        case .results, .stopped:
            OverviewCopy.subtitleResults(safe: Formatting.bytes(model.totals?.safeBytes ?? 0),
                                         review: Formatting.bytes(model.totals?.reviewBytes ?? 0),
                                         keep: Formatting.bytes(model.totals?.keepBytes ?? 0))
        }
    }

    static func stageName(_ stage: CareStage) -> String {
        switch stage {
        case .rules: OverviewTarget.chipTitle(.aiTools)
        case .index: loc("care.stage.index", "your files")
        case .largeOld: OverviewTarget.chipTitle(.largeOld)
        case .duplicates: OverviewTarget.chipTitle(.duplicates)
        case .apps: OverviewTarget.chipTitle(.apps)
        case .startup: OverviewTarget.chipTitle(.startup)
        }
    }

    var body: some View {
        SectionCard(padding: ADKTheme.Spacing.xl) {
            HStack(alignment: .top, spacing: ADKTheme.Spacing.xl) {
                PrimaryButton(model: model, reduceMotion: reduceMotion, onReview: onReview)
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
                    Text(eyebrow).font(.caption.weight(.semibold)).foregroundStyle(.adkAccent).textCase(nil)
                    HeroNumberText(headline)
                        .contentTransition(.numericText())
                        .animation(StrataMotion.animation(reduceMotion: reduceMotion), value: headlineValue)
                    Text(subtitle).font(.callout).foregroundStyle(.adkText2).fixedSize(horizontal: false, vertical: true)
                    if showFirstRunNote {
                        Text(loc("index.gate.message", "AI Disk Keeper reads folder sizes only, never file contents. macOS may ask for access to Desktop, Documents and Downloads; if you decline, those folders are shown as locked."))
                            .font(.caption).foregroundStyle(.adkText3).fixedSize(horizontal: false, vertical: true)
                    }
                    CarePhaseChips(model: model)
                        .padding(.top, ADKTheme.Spacing.xs)
                    HStack(spacing: ADKTheme.Spacing.md) {
                        Button(OverviewCopy.cleanSafe, action: onCleanSafe)
                            .disabled(model.phase != .results || model.safeBulkBytes <= 0)
                        if model.phase == .stopped {
                            Label(OverviewCopy.stopped, systemImage: "pause.circle").font(.caption.weight(.medium))
                                .foregroundStyle(.adkReviewInk)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.adkReviewSoft, in: Capsule())
                        }
                        if model.phase == .results, let line = model.growthLine {
                            Label(line, systemImage: "chart.line.uptrend.xyaxis").font(.caption).foregroundStyle(.adkText2)
                        }
                    }
                    .padding(.top, ADKTheme.Spacing.xs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.adkAccentSoft.opacity(0.35), in: RoundedRectangle(cornerRadius: ADKTheme.Radius.lg))
    }

    /// The 88 pt circle: Scan (⌘R), Stop (Esc) while scanning, Review with the reviewable bytes in the results.
    private struct PrimaryButton: View {
        let model: CareScanModel
        let reduceMotion: Bool
        let onReview: () -> Void
        @Environment(\.adkIncreasedContrast) private var increasedContrast

        var body: some View {
            let action = model.primaryAction
            roundButton(action)
                .accessibilityLabel(label(action))
                .animation(StrataMotion.animation(reduceMotion: reduceMotion), value: model.progressFraction)
        }

        /// Esc stops the scan only while one is running.
        @ViewBuilder private func roundButton(_ action: CareScanModel.PrimaryAction) -> some View {
            if action == .stop {
                face(action).keyboardShortcut(.cancelAction)
            } else {
                face(action)
            }
        }

        private func face(_ action: CareScanModel.PrimaryAction) -> some View {
            Button { perform(action) } label: {
                VStack(spacing: 1) {
                    Text(title(action)).font(.headline)
                    Text(caption(action)).font(.caption2).opacity(0.85).lineLimit(1).minimumScaleFactor(0.6)
                }
                .foregroundStyle(.adkOnAccent)
                .frame(width: 88, height: 88)
                .background(.adkAccent, in: Circle())
                .overlay { ring }
                .overlay { if increasedContrast { Circle().strokeBorder(.adkLineStrong, lineWidth: 2) } }
            }
            .buttonStyle(.plain)
        }

        @ViewBuilder private var ring: some View {
            if model.phase == .scanning, CareHero.ringStyle(reduceMotion: reduceMotion) == .sweep {
                Circle().trim(from: 0, to: max(0.02, model.progressFraction))
                    .stroke(.adkOnAccent.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(5)
            } else if model.phase == .scanning {
                Circle().strokeBorder(.adkOnAccent.opacity(0.5), lineWidth: 3).padding(5)   // static ring
            }
        }

        private func perform(_ action: CareScanModel.PrimaryAction) {
            switch action {
            case .scan: model.start()
            case .stop: model.stop()
            case .review: onReview()
            }
        }

        private func title(_ action: CareScanModel.PrimaryAction) -> String {
            switch action {
            case .scan: OverviewCopy.buttonScan
            case .stop: OverviewCopy.buttonStop
            case .review: OverviewCopy.buttonReview
            }
        }

        private func caption(_ action: CareScanModel.PrimaryAction) -> String {
            switch action {
            case .scan: "⌘R"
            case .stop:
                CareHero.ringStyle(reduceMotion: reduceMotion) == .static
                    ? Formatting.count(Int((model.progressFraction * 100).rounded())) + "%" : "Esc"
            case .review(let bytes): Formatting.bytes(bytes)
            }
        }

        private func label(_ action: CareScanModel.PrimaryAction) -> String {
            switch action {
            case .scan: OverviewCopy.a11yScan
            case .stop: OverviewCopy.a11yStop
            case .review(let bytes): OverviewCopy.a11yReview(Formatting.bytes(bytes))
            }
        }
    }
}
