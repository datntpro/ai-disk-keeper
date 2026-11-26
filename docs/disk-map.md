# Disk map layout engine (T30)

Pure geometry over a `DiskTree` (T29): no file I/O, no actors, no clocks, no UI types (`LayoutRect`, not `CGRect`;
T31 converts). Every function is synchronous and deterministic: identical inputs give an identical `elements` array.
Sizes are always `allocatedBytes`; zero-byte nodes are not drawn and do not count as hidden children.

Source: `Sources/DiskKeeperCore/Map/`.

## Strata (icicle / partition) — `DiskMapLayout.strata`
Row height `h = (H − (rows−1)·rowGap) / rows`; row 0 is the focus at full width. Each node's span is divided among its
children by `bytes / node.bytes`. Boundaries come from **cumulative sums**, never from adding widths, so there is no
drift, gap or overlap. A child that would be narrower than `minimumWidth` ends the loop (children are sorted by size,
so the rest are smaller): the tail is summed once and drawn as **one `.aggregate` per parent** (`count`, `bytes`),
placed after the last drawn child. The directory's own blocks (bytes − Σ children) stay empty at the right end of the
span. A child larger than what is left of its parent is clamped, so nothing is drawn outside its parent.
`hasHiddenChildren` is true for collapsed nodes (packages), nodes cut by the row limit, and parents that got an aggregate.

Complexity: O(E + skipped tails), E ≤ rows · W / minimumWidth (6 · 1600 / 2 = 4 800). Order: row-major, x ascending.

## Squarified tiles — `DiskMapLayout.tiles`
Bruls–Huizing–van Wijk (2000) over the focus's children (areas scaled so Σ = area(viewport)). Strips run along the
shorter side with thickness `Σ row / side`; offsets inside a strip are cumulative; the last strip takes the exact remaining
extent. Tiles whose scaled area is below `minimumArea` merge into one trailing aggregate tile. Level 2 (`levels = 2`):
a level-1 tile with area ≥ 4·`minimumArea` is inset by `padding`, `headerHeight` is cut off the top (when the box is
taller than twice the header), and its children are squarified inside; the own-bytes gap is an invisible last item, so
child areas stay proportional to bytes and the gap is left empty. Complexity O(n₁ + Σ n₂).

## Hit testing — `element(at:)`, `element(for:)`
Rects are half-open `[x, x+w) × [y, y+h)`: a shared edge belongs to the right/lower element. Edges are stored as `x`/`width`, so neighbouring tiles agree to within 1 ULP: at an exact corner point `element(at:)` may return the earlier sibling (harmless for UI).
- Strata: row from `y`, then binary search over that row's x-sorted elements. Row gaps, empty own-bytes space and points
  outside the viewport return nil. O(log n).
- Tiles: scan level-1 tiles, then that tile's level-2 tiles; the deepest hit wins. Header strips, padding and empty
  own-bytes space return the enclosing element; outside the viewport returns nil.
- `element(for:)` is O(1) (`[DiskNodeID: Int]` built with the layout).

## Overlay — `DiskMapOverlay`
`build(tree:items:)` maps each `ScanItem` path to the deepest materialized node (case/Unicode-insensitive, like
`DiskTree.lookup`). An exact path match sets `isExact`; an item inside a collapsed package or small-items node lands on that
node with `isExact = false`. Items outside the tree root are ignored (`unmappedItemCount`). Bytes, categories, tools and
risk tiers propagate to all ancestors; `attributedBytes` is capped at the node's bytes. `itemIDs` are the items whose
deepest node is exactly this node (for "Review in list"). Ties: first `ItemCategory.allCases` entry, then smallest `ToolID`.
`ageBucket(_:now:)`: <30 d, <183 d, <365 d, <3·365 d, older, nil → unknown.

## Notes for the UI (T31)
Aggregate elements always have `isProtected = false` (they merge several nodes and carry no flags): render them neutrally,
and never read the hatched/protected style from them.

## Viewer invariant (PLAN invariant 12)
The map is a viewer. No type in `Map/` stores or creates a `ScanItem` (only `ScanItem.ID` strings) or references cleanup
types; the only route to cleanup stays the list/plan flow. `DiskMapSafetyTests` greps the sources for cleanup and
file-removal APIs and for UI framework imports. Protected and outside-root nodes are flagged (`isProtected`, from tree
flags only) and never hidden, so sizes stay honest. The overlay never changes `isProtected`.
The map has no user-facing text (labels are the UI's job, T31).

## Performance (`DiskMapPerfTests`, release, 320k-node synthetic tree, fan-out 20)
| Operation | Bound | Measured (median of 10) |
|---|---|---|
| `strata` 1600×600 | < 5 ms | ~0.13 ms |
| `tiles` 2 levels 1600×600 | < 10 ms | ~0.07 ms |
| `DiskMapOverlay.build`, 5 000 items | < 20 ms | ~17 ms |

Debug builds use a ×100 bound (a sanity check only; unoptimized code on shared CI runs 30–50× slower). Layout cost depends on the drawn elements, not on tree size.
