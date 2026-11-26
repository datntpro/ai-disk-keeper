import DiskKeeperCore
import SwiftUI

/// "Select all Safe in <scope> (N · X GB)" plus "Deselect all". `items` is the current sidebar scope.
public struct SelectAllSafeButton: View {
    let items: [ScanItem]
    let scopeName: String?
    let selection: SelectionModel

    public init(items: [ScanItem], scopeName: String?, selection: SelectionModel) {
        self.items = items
        self.scopeName = scopeName
        self.selection = selection
    }

    public var body: some View {
        let safe = items.filter(\.isBulkSelectable)
        let bytes = safe.reduce(Int64(0)) { $0 + $1.sizeAllocated }
        HStack {
            Button(CleanupCopy.selectAllSafeTitle(scope: scopeName, count: safe.count, bytes: bytes)) {
                selection.selectAllSafe(in: items)
            }
            .disabled(safe.isEmpty)
            Button(CleanupCopy.deselectAll) { selection.deselectAll() }
                .disabled(selection.selectedIDs.isEmpty)
        }
    }
}
