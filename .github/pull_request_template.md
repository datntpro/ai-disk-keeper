## Summary

## Checklist
- [ ] UI text uses `loc("key", "English")`; ran `python3 -I scripts/l10n-extract.py --sync` and filled in **en and vi**
- [ ] Core-originated text has a code/enum in Core and a mapping in `CoreCopy.swift`; rule text has `localized.vi`
- [ ] Numbers, bytes and dates go through `Formatting.*`
- [ ] New screens checked with `--pseudo-localize` and in Vietnamese
- [ ] `swift test` passes
