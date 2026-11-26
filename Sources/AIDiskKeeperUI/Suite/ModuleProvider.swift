import SwiftUI

/// One conformer per module, each in its own folder under `Modules/`. A screen PR edits only its own provider.
public protocol ModuleProvider: Sendable {
    static var descriptor: ModuleDescriptor { get }
    @MainActor static func badge(_ ctx: ModuleContext) -> ModuleBadge?
    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView
    /// `nil` → the shared item inspector.
    @MainActor static func makeInspector(_ ctx: ModuleContext) -> AnyView?
}

extension ModuleProvider {
    @MainActor static func badge(_ ctx: ModuleContext) -> ModuleBadge? { nil }
    @MainActor static func makeInspector(_ ctx: ModuleContext) -> AnyView? { nil }
}
