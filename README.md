# AI Disk Keeper

A native macOS app (SwiftUI, macOS 14+) that **finds, explains and safely cleans** disk usage
created by AI coding tools and their side effects:

- AI tool data — Claude Code (`~/.claude`), Claude desktop, Cursor, Codex, Gemini / Antigravity,
  Kiro, Copilot, Windsurf, Aider, Continue, Orca workspaces…
- Agent worktrees and stray git worktrees, classified by git state (merged & clean vs. dirty/unpushed)
- Per-worktree build artifacts and dependency dirs (`node_modules`, `.venv`, `target/`, `.next`, `DerivedData`…)
- Local model weights (Ollama, LM Studio, Hugging Face) — reviewed per model, never bulk-deleted
- System junk those tools leave behind (logs, crash reports, caches, scratch dirs, Docker data)

Scanning is **read-only by default**. Every item gets a risk tier — **Safe / Review / Keep** — with
a plain-language explanation. Cleanup moves to the Trash by default, always shows a dry-run
preview first, writes an audit log, and never touches credentials, auth or config files.

> Status: scaffold only. See [docs/PLAN.md](docs/PLAN.md) for the plan, architecture and milestones.

## Build & test

Requires macOS 14+ and **Xcode 16+** (full Xcode is needed for `swift test`; Command Line Tools alone
can `swift build` but have no XCTest).

```sh
swift build            # build core library + app executable
swift test             # run XCTest suite
swift run AIDiskKeeper # launch the (scaffold) app
```

You can also open `Package.swift` in Xcode.

> **Select the full Xcode toolchain.** The UI's String Catalog (`.xcstrings`) is compiled by `xcstringstool`, which
> ships with Xcode, not the Command Line Tools. If `swift build` fails with `xcstringstool is not an executable file`:
> `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (or `sudo xcode-select -s /Applications/Xcode.app`).

### Localization (English + Vietnamese)

All UI text lives in `Sources/AIDiskKeeperUI/Resources/Localizable.xcstrings`. When you add or change UI text:

1. Write it as `loc("area.screen.thing", "English default")`. Keys are dot-separated, lowerCamel, grouped by feature.
   Never reuse a key for a different meaning. Never hard-code user-facing text (no bare `Text("…")`).
2. Run `python3 -I scripts/l10n-extract.py --sync`, then fill in **both** `en` and `vi` in the catalog
   (`scripts/l10n-apply.py` merges a `{key: text}` Python dict). `vi` may be `needs_review`, never `new`.
   CI runs `scripts/l10n-extract.py --check` and `CatalogLintTests`.
3. Text that Core produces (warnings, denials, categories) gets a stable code/enum case in Core and a mapping in
   `Shared/CoreCopy.swift`; rule text gets `localized.vi` in the rule JSON (see `docs/rules.md`).
4. Use `Formatting.*` for numbers, bytes and dates. Never interpolate a raw `Double` or `Date`.
5. Check new screens with `swift run AIDiskKeeper --pseudo-localize` (debug builds) and with Vietnamese selected.

Vietnamese copy follows the approved glossary (An toàn / Cần xem / Giữ lại, Quét, Dọn dẹp, Chuyển vào Thùng rác,
Nhật ký thao tác, Toàn quyền truy cập ổ đĩa, Tệp mô hình; Worktree and cache stay in English; new-style tone marks:
`xóa`, `hòa`), sentence case, natural wording, no pronoun unless needed.

### Package the app

```sh
./scripts/make-app.sh                 # → dist/AI Disk Keeper.app (host arch, ad-hoc signed)
./scripts/make-app.sh --universal --zip
open "dist/AI Disk Keeper.app"
```

Flags: `--config release|debug`, `--universal` (arm64 + x86_64, needs full Xcode), `--output DIR`,
`--zip`, `--no-sign`, `--skip-verify`. Env overrides: `BUNDLE_ID` (default
`io.github.datntpro.aidiskkeeper`), `VERSION`, `BUILD_NUMBER`.

The result is **ad-hoc signed, not notarized** (Developer ID signing and notarization come later).
A zip downloaded from CI is quarantined by macOS: open it via System Settings → Privacy & Security →
"Open Anyway", or run `xattr -dr com.apple.quarantine "AI Disk Keeper.app"`.
CI builds the app on every PR; the zip is uploaded as an artifact only on `main`
(Actions run → Artifacts).
`AIDiskKeeper --verify-resources` prints where the bundled resources resolve (used by the script).

## Layout

```
Package.swift
Sources/DiskKeeperCore/   # scan engine, scanner rules, safety policy, cleanup engine (no UI)
Sources/AIDiskKeeper/     # SwiftUI app (window + menu bar)
Tests/DiskKeeperCoreTests/
scripts/                  # make-app.sh (.app packaging), placeholder icon generator
Packaging/                # Info.plist template
docs/PLAN.md
```

CI (`.github/workflows/ci.yml`) builds and tests on a GitHub-hosted macOS runner for every PR.

## Releasing

Tagged releases (`vX.Y.Z`) are built, Developer ID signed, notarized and published as a DMG by
`.github/workflows/release.yml`; without Apple secrets they fall back to an unsigned draft release.
See [docs/RELEASING.md](docs/RELEASING.md) for owner setup, dry runs and troubleshooting.
