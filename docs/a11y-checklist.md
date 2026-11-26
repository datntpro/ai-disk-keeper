# T46 — states and accessibility checklist

Status: **code + unit tests done; first-pass VM QA done (Tart `adk-pr117`, AX dumps + offscreen renders): Overview first run, Not scanned, Empty, sidebar gear, keyboard order and AX labels pass. Not covered: the FDA banner live (base image has FDA granted), index/startup/cleanup blocking errors (need fault injection), live dark mode and Larger Text.** Everything runs in the Tart VM, never the owner's Mac. "Wired" means the view uses `StateView` + `StateCopy`; "—" means the state does not exist for that module.

## Building blocks
`StateView` (glyph tile, one prominent action) · `StateCopy` (all copy) · `ModuleStateResolver` (+ tests) · `FDABanner` ("Not now" lasts until relaunch, `@SceneStorage`) · `.adkBarBackground()` (Reduce Transparency; a source test bans raw `.bar`/Material) · sidebar Settings gear (`SettingsGearButton`).

## Module × state
| Module | First run | FDA optional | Empty | Filtered empty | Partial error | Blocking error |
|---|---|---|---|---|---|---|
| Overview / Care | Wired (`EmptyStateView`: title, body, "What gets scanned?") | existing warnings link | existing | — | existing link to Warnings | follow-up (no coordinator throw path exists today) |
| AI Tools / Worktrees / Models & Docker | Wired ("Not scanned yet" + Scan) | Wired (`FDABanner`) | Wired ("No %@ data found") | Wired + Clear search | follow-up | — |
| Disk Map / Large & Old / Duplicates | existing gate (N4 consent text kept) | existing | existing | existing | existing | Wired in `IndexGateView` (`.blockingError`, "Nothing was changed") |
| Storage | — | existing | — | — | existing | existing (restyled by `StateView`) |
| Uninstaller | — | — | existing | existing | existing | existing (restyled by `StateView`) |
| Startup | — | — | existing | — | existing | Wired (adds "Nothing was changed") |
| Cleanup sheet | — | — | follow-up | — | — | Wired (`.failed` → `.blockingError`) |
| Warnings | — | — | follow-up | — | — | — |

## Accessibility pass
- [x] Reduce Transparency: bars use `.adkBarBackground()`.
- [x] Increase Contrast: `StateView` glyph tile and `FDABanner` add `adkLineStrong` borders.
- [x] Settings gear: label + help "Settings"/"Cài đặt", a real `SettingsLink`, so Tab/VoiceOver reach it.
- [ ] Accessibility Inspector audit per screen (VM).
- [ ] Keyboard-only run, VoiceOver run, largest text, Reduce Motion audit (VM).
