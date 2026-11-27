import Foundation

/// The single list of modules. A new module is a new provider file plus one line here, nothing else.
public enum ModuleRegistry {
    /// ALL thirteen, in the fixed sidebar order (the order tests pin).
    public static let providers: [any ModuleProvider.Type] = [
        OverviewModule.self, CareScanModule.self, DiskMapModule.self, LargeOldModule.self, DuplicatesModule.self,
        StorageModule.self, AIToolsModule.self, WorktreesModule.self, ModelsDockerModule.self,
        UninstallerModule.self, StartupItemsModule.self, DiskActivityModule.self, HistoryModule.self,
    ]

    /// Debug builds also list modules that are not built yet (their detail is a stub).
    public static var showsUnbuilt: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    public static func enabled() -> [ModuleDescriptor] { providers.map { $0.descriptor }.filter(\.isEnabled) }
    public static var enabledIDs: Set<ModuleID> { Set(enabled().map(\.id)) }

    public static func descriptor(for id: ModuleID) -> ModuleDescriptor { provider(for: id).descriptor }

    public static func provider(for id: ModuleID) -> any ModuleProvider.Type {
        // Providers are unique and exhaustive (pinned by ModuleRegistryTests).
        providers.first { $0.descriptor.id == id }!
    }

    /// Non-empty sections in order, each with its modules sorted by `order`.
    public static func sections(includeDisabled: Bool = false) -> [(ModuleSection, [ModuleDescriptor])] {
        let all = providers.map { $0.descriptor }.filter { includeDisabled || $0.isEnabled }
        return ModuleSection.allCases.compactMap { section in
            let rows = all.filter { $0.section == section }.sorted { $0.order < $1.order }
            return rows.isEmpty ? nil : (section, rows)
        }
    }
}
