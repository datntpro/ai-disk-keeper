import SwiftUI

/// Placeholder until the Disk Map screen (#62) lands; flip `isEnabled` there.
enum DiskMapModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .diskMap, section: .storage, order: 1, symbol: "square.stack.3d.down.right",
                                             isEnabled: false)

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(ModuleStub(descriptor: descriptor))
    }
}
