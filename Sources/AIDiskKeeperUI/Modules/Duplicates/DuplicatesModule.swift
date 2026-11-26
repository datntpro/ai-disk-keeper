import SwiftUI

/// Placeholder until the Duplicates screen (#64) lands; flip `isEnabled` there.
enum DuplicatesModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .duplicates, section: .storage, order: 3, symbol: "doc.on.doc",
                                             isEnabled: false)

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(ModuleStub(descriptor: descriptor))
    }
}
