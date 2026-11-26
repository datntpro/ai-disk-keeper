#if DEBUG
import DiskKeeperCore
import SwiftUI

/// Every Strata component in one grid, for previews and eyeballing the theme.
struct StrataGallery: View {
    static let segments: [StrataSegment] = StrataLayer.allCases.enumerated().map { i, l in
        StrataSegment(id: "\(l)", layer: l, bytes: Int64(12 - i) * 1_000_000_000, label: l.title)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(verbatim: "Strata gallery").font(ADKTheme.Font.largeTitle)
                HeroNumberText("48.2 GB")
                StrataBar(segments: Self.segments, total: 120_000_000_000, free: 30_000_000_000)
                HStack { ForEach(StrataLayer.allCases, id: \.self) { LegendChip(color: $0.color, label: $0.title) } }
                HStack { ForEach(RiskTier.allCases, id: \.self) { TierBadge(tier: $0) }; TierBadge(tier: .safe, compact: true) }
                HStack { ForEach(StatusPill.Kind.allCases, id: \.self) { StatusPill(kind: $0) } }
                HStack { SizeText(1_234_567_890); SizeText(1_234_567_890, qualifier: .upTo); SizeText(1_234_567_890, qualifier: .estimate) }
                PathText("/Users/someone/Library/Caches/com.example.tool/very/long/nested/path/file.bin")
                ModuleTile(symbol: "map", title: "Disk Map", bytes: 9_200_000_000,
                           tierSplit: [.safe: 3_100_000_000, .review: 4_000_000_000, .keep: 2_100_000_000], badge: "New") {}
                    .frame(maxWidth: 260)
                SectionCard { Text(verbatim: "Section card") }
                HStack(spacing: 12) { ForEach(0..<6) { i in RoundedRectangle(cornerRadius: 4).fill(AgeRamp.color(AgeBucket.allCases[i])).frame(width: 40, height: 20) } }
                HatchPattern().stroke(.adkLine, lineWidth: 1).frame(height: 30)
                StateView(kind: .empty, symbol: "tray", title: "Nothing here", message: "Run a scan.", actions: [StateAction(title: "Scan") {}])
                    .frame(height: 220)
                SelectionActionBar(bytes: 2_000_000_000, countLabel: "3 items", hint: "Moves to Trash", primaryTitle: "Clean up", count: 3) {}
            }
            .padding(24)
        }
        .background(.adkBg)
    }
}

#Preview("Light") { StrataGallery().frame(width: 720, height: 900) }
#Preview("Dark") { StrataGallery().preferredColorScheme(.dark).frame(width: 720, height: 900) }
#Preview("Increased contrast") {
    StrataGallery().environment(\.adkIncreasedContrast, true).frame(width: 720, height: 900)
}
#endif
