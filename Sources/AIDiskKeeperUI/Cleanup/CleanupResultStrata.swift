import SwiftUI

/// Free space before and after emptying the Trash. Both bars share one scale (the "after" free space), so the
/// freed layer reads as growth. Hidden by the caller when the free space before is unknown.
struct CleanupResultStrata: View {
    let freeBefore: Int64
    let freed: Int64
    /// False in static renders (snapshots), where `onAppear` never runs.
    var animatesIn = true

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.adkIncreasedContrast) private var increasedContrast

    private var freeAfter: Int64 { freeBefore + max(freed, 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
            label(CleanupCopy.resultBefore(freeBefore))
            bar(beforeFraction: 1, freedFraction: 0)
            label(CleanupCopy.resultAfter(freeAfter))
            bar(beforeFraction: before, freedFraction: shown || reduceMotion || !animatesIn ? 1 - before : 0)
        }
        .onAppear { shown = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CleanupCopy.resultBefore(freeBefore) + ". " + CleanupCopy.resultAfter(freeAfter))
    }

    /// Share of the "after" scale that is already free before cleaning.
    private var before: Double { freeAfter > 0 ? Double(freeBefore) / Double(freeAfter) : 1 }

    private func label(_ s: String) -> some View { Text(s).font(.caption).foregroundStyle(.adkText2).monospacedDigit() }

    /// `beforeFraction` of the scale is the already-free layer (hatched in the "before" bar, solid in "after"),
    /// `freedFraction` is the freed layer in `.adkSafe`.
    private func bar(beforeFraction: Double, freedFraction: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .trailing) {
                Rectangle().fill(.adkSunken)
                Canvas { ctx, size in
                    HatchPattern.draw(in: ctx, rect: CGRect(x: 0, y: 0, width: size.width * beforeFraction, height: size.height),
                                      color: .adkLine)
                }
                Rectangle().fill(.adkSafe)
                    .frame(width: freedFraction > 0 ? max(w * freedFraction, 4) : 0)
                    .clipped()
            }
            .strataAnimation(freedFraction)
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(increasedContrast ? .adkLineStrong : .adkLine, lineWidth: ADKTheme.hairline)
        }
    }
}
