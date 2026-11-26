import SwiftUI

/// Placeholder until the Storage screen (T40 UI) lands; flip `isEnabled` there.
enum StorageModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .storage, section: .storage, order: 4, symbol: "internaldrive",
                                             isEnabled: false)

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(ModuleStub(descriptor: descriptor))
    }
}
