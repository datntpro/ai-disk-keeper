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

## UI (T31)
Source: `Sources/AIDiskKeeperUI/Modules/DiskMap/`. The screen is a viewer over the one `DiskIndexModel` tree (invariant 12);
`DiskMapSafetyTests` greps this folder for cleanup, selection and file-removal APIs and expects none.

- **Model.** `DiskMapModel` (`@MainActor @Observable`, kept in `suite.state(.diskMap)` so the detail and the inspector share
  it) owns focus, mode (Strata | Tiles), colouring (category | age), filter, hover, selection and the zoom morph.
  Layout runs in `Task.detached` (`DiskMapLayoutWorker`); every request has a token and stale results are dropped.
  Strata: `StrataOptions(rows: 6, minimumWidth: 2, rowGap: 1)`; Tiles: `TileOptions(levels: 2, minimumArea: 24)`.
  Hovering only hit-tests (`element(at:)`), it never lays out. A new tree keeps the focus when its path still exists.
- **Overlay.** `DiskMapOverlay.build` runs detached from `scan.items` whenever the scan changes. Without a scan the map
  colours everything as "Other" and shows a hint chip. (Items of Large & Old / Duplicates are not merged in yet: those
  modules don't exist; add them where `DiskMapModule.model` builds the model.)
- **Rendering.** One base `Canvas` pass (`DiskMapCanvas`, no per-element views) and a second `Canvas` for hover and
  selection rings (`DiskMapHighlight`), so a hover sweep redraws a few strokes. Protected nodes: `keepSoft` + hatch + lock;
  aggregates are neutral (`Other` at 60 %) and never hatched. Labels use `Contrast.labelInk` and are skipped when no ink
  reaches 4.5:1. The filter dims non-matching elements to 25 %; it does not change the layout.
- **Interaction.** Click selects, a second click on the selected directory zooms (so double-click zooms); ⌘↑ / Esc zoom out.
  Arrows move (siblings in size order, ↓ largest child, ↑ parent), Return zooms. The context menu offers Zoom in, Reveal in
  Finder and Copy path only. "Review in list" navigates (`NavigationModel.show`) and never selects.
- **Accessibility.** `axRows` (focus's children, capped at 200, plus the selection's ancestors) are invisible proxies with
  default action = zoom, "Reveal in Finder" and "Review in list"; a rotor lists the largest folders. VoiceOver is told
  "name, size, N percent of focus" on selection changes, only while it is running.
- **Motion.** The zoom morph interpolates rectangles by node id over 0.45 s (`StrataMotion.progress`); nodes only in the new
  layout fade in. Reduce Motion: a 0.2 s cross-fade, no movement.

### UI performance (`DiskMapPerfTests`, release, ~66 000-node synthetic tree, median of 10)
| Operation | Bound | Measured |
|---|---|---|
| 10 000 hover hit-tests | < 20 ms | 0.37 ms |
| layout round trip through the model | < 8 ms | 0.13 ms |
| colouring all elements (566) | < 2 ms | 0.004 ms |
| `ImageRenderer`, base canvas 1400×600 | < 12 ms | 1.8 ms |
| `ImageRenderer`, highlight canvas | < 1 ms | 0.06 ms |

The Instruments trace (SwiftUI + Time Profiler, hover sweep on a real Home index) is a manual owner check.
