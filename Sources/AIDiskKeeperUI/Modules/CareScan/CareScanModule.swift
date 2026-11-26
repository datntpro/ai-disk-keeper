import SwiftUI

/// Stays hidden: Overview *is* the Care Scan (T43, decision 1). Enabling this later would add a combined results list.
enum CareScanModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .careScan, section: .top, order: 2, symbol: "sparkles",
                                             isEnabled: false)

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(ModuleStub(descriptor: descriptor))
    }
}
