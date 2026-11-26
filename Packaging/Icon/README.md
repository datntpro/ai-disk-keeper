# Strata app icon

Original artwork for AI Disk Keeper: four stacked, rounded, offset layers (sediment) on a light squircle tile, teal on top.
Colours come from `StrataPalette` (accent `#0B847B`, `.junk` clay `#B4615A`, a darkened `.other` slate `#5C616C`, a sand tone).
Original work, © the project, same licence as the repo. No SF Symbols, third-party art, fonts or generated images.

- `StrataMark.json` — geometry and colours (source of truth; `small` = 3-layer variant for ≤ 32 px; `glyph` = menu bar template constants).
- `strata-mark.svg` — hand-checked SVG of the 4-layer geometry at 1024.

Regenerate: `swift scripts/make-icon.swift Packaging/Icon/StrataMark.json /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset`
(`scripts/make-app.sh` does this on every build). The menu bar glyph is drawn in code: `Sources/AIDiskKeeperUI/Theme/StrataGlyph.swift`.

Layout: the tile artwork is 824/1024 of the canvas, centred (~100 px margin, macOS icon grid) with a soft shadow; ≤ 32 px variants snap layers to whole pixels with ≥ 1 px gaps.
