import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class ComponentRenderSmokeTests: XCTestCase {
    private let segments = StrataLayer.allCases.enumerated().map {
        StrataSegment(id: "\($0.offset)", layer: $0.element, bytes: Int64(10 - $0.offset) * 1_000_000, label: $0.element.title)
    }

    private func components() -> [(String, AnyView)] {
        [
            ("TierBadge", AnyView(HStack { ForEach(RiskTier.allCases, id: \.self) { TierBadge(tier: $0) }; TierBadge(tier: .safe, compact: true) })),
            ("StatusPill", AnyView(HStack { ForEach(StatusPill.Kind.allCases, id: \.self) { StatusPill(kind: $0) } })),
            ("StrataBar", AnyView(StrataBar(segments: segments, total: 100_000_000, free: 20_000_000).frame(width: 400))),
            ("ModuleTile", AnyView(ModuleTile(symbol: "map", title: "Disk Map", bytes: 9_000_000_000, tierSplit: [.safe: 3, .review: 4, .keep: 2], badge: "New") {}.frame(width: 240))),
            ("SizeText", AnyView(VStack { SizeText(1_234_567); SizeText(1_234_567, qualifier: .upTo); SizeText(1_234_567, qualifier: .estimate) })),
            ("PathText", AnyView(PathText("/Users/x/Library/Caches/very/long/path").frame(width: 160))),
            ("StateView", AnyView(StateView(kind: .progress(0.4), symbol: "magnifyingglass", title: "t", message: "m", actions: [StateAction(title: "Go") {}]).frame(width: 300, height: 200))),
            ("SelectionActionBar", AnyView(SelectionActionBar(bytes: 5, countLabel: "2 items", hint: "hint", primaryTitle: "Clean", count: 2) {}.frame(width: 500))),
            ("LegendChip", AnyView(LegendChip(color: .adkAccent, label: "Label"))),
            ("HatchPattern", AnyView(HatchPattern().stroke(.adkLine).frame(width: 100, height: 40))),
            ("SectionCard", AnyView(SectionCard { Text(verbatim: "card") })),
            ("HeroNumberText", AnyView(HeroNumberText("12.3 GB"))),
        ]
    }

    func testEveryComponentRendersInEveryMode() {
        for (name, view) in components() {
            for (scheme, increased) in [(ColorScheme.light, false), (.dark, false), (.light, true)] {
                let r = ImageRenderer(content: view
                    .environment(\.colorScheme, scheme)
                    .environment(\.adkIncreasedContrast, increased)
                    .padding())
                guard let img = r.cgImage else { XCTFail("\(name) \(scheme) hc=\(increased) did not render"); continue }
                XCTAssertGreaterThan(img.width, 0, name)
                XCTAssertGreaterThan(img.height, 0, name)
            }
        }
    }
}
