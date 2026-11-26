import SwiftUI

/// Wraps the existing `OverviewView`. Selected as `SidebarSelection.overview`.
enum OverviewModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .overview, section: .top, order: 1,
                                             symbol: "gauge.with.dots.needle.33percent", isEnabled: true)

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        let scan = ctx.scan
        return AnyView(
            OverviewView(scan: scan, inspect: { ctx.inspectedID.wrappedValue = $0 },
                         showWarnings: { ctx.suite.navigation.selection = .warnings }) {
                if scan.phase != .idle {
                    SelectAllSafeButton(items: scan.items, scopeName: nil, selection: ctx.scanSelection)
                }
            })
    }
}
