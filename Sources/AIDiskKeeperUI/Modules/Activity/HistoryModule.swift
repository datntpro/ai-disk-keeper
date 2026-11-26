import SwiftUI

/// Placeholder until the Cleanup History screen (T24) lands; flip `isEnabled` there.
enum HistoryModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .history, section: .activity, order: 1, symbol: "clock.arrow.circlepath",
                                             isEnabled: false)

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(ModuleStub(descriptor: descriptor))
    }
}
