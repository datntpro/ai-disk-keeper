import DiskKeeperCore
import SwiftUI

/// Everything a module needs, handed in by `RootView`. Modules never reach for globals.
@MainActor
public struct ModuleContext {
    let env: AppEnvironment
    let scan: ScanViewModel
    let suite: SuiteModel
    /// The scan-item selection behind the toolbar's cleanup button.
    let scanSelection: SelectionModel
    /// Rows for the shared item table (already filtered and sorted).
    let list: ItemListModel
    let query: Binding<ItemQuery>
    let inspectedID: Binding<ScanItem.ID?>
}
