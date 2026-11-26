import SwiftUI

/// Placeholder detail for a module whose screen hasn't landed yet (shown in debug builds only).
struct ModuleStub: View {
    let descriptor: ModuleDescriptor

    var body: some View {
        StateView(kind: .empty, symbol: descriptor.symbol, title: loc("module.stub.title", "Not available yet"),
                  message: loc("module.stub.message", "\(descriptor.title) is still being built."))
    }
}
