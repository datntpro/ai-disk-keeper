import SwiftUI

/// Placeholder until the Startup Items screen (T38) lands; flip `isEnabled` there.
enum StartupItemsModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .startupItems, section: .apps, order: 2, symbol: "power.circle",
                                             isEnabled: false)

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(ModuleStub(descriptor: descriptor))
    }
}
