import SwiftUI

/// Placeholder until the Uninstaller screen (T37) lands; flip `isEnabled` there.
enum UninstallerModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .uninstaller, section: .apps, order: 1, symbol: "xmark.app",
                                             isEnabled: false)

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(ModuleStub(descriptor: descriptor))
    }
}
