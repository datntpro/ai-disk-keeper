import SwiftUI

/// Placeholder until Care Scan (T44/T43) lands; flip `isEnabled` there.
enum CareScanModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .careScan, section: .top, order: 2, symbol: "sparkles",
                                             isEnabled: false)

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(ModuleStub(descriptor: descriptor))
    }
}
