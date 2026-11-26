import SwiftUI

/// `Home › Library › Developer`: each crumb but the last is a link button.
struct DiskMapBreadcrumbs: View {
    let crumbs: [Crumb]
    let onSelect: (Crumb) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(crumbs.enumerated()), id: \.element.id) { i, crumb in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.adkText3).accessibilityHidden(true) }
                if i == crumbs.count - 1 {
                    Text(crumb.name).font(.callout.weight(.semibold)).lineLimit(1)
                } else {
                    Button(crumb.name) { onSelect(crumb) }
                        .buttonStyle(.link).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DiskMapCopy.breadcrumbs)
    }
}
