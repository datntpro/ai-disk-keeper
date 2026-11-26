import SwiftUI

/// Placeholder until the Large & Old screen (#63) lands; flip `isEnabled` there.
enum LargeOldModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .largeOld, section: .storage, order: 2, symbol: "doc.badge.clock",
                                             isEnabled: false)

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(ModuleStub(descriptor: descriptor))
    }
}
