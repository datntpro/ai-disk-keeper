#!/usr/bin/env python3
"""Merges {key: vi text} Python dict files (variable VI, and WHY for `protected.why.*` keys) into Localizable.xcstrings.

Usage:
  python3 -I scripts/l10n-apply.py <file.py> [<file.py> ...]   apply (state needs_review)
  python3 -I scripts/l10n-apply.py --verify [<file.py> ...]    check only (default: scripts/l10n/*.vi.py); used by CI

Apply is idempotent: a key whose vi value already equals the file's value and whose state is `translated` or
`needs_review` is left alone, so a reviewed string is never set back to needs_review. An unknown key is an error (exit 1).

--verify fails when a vi-file key is missing from the catalog, its catalog vi text differs from the file, a key
appears in two vi files, or a key lacks the file's allowed prefix. A file may declare `PREFIXES = ("apps.",)`;
otherwise the defaults below apply (files not listed there are not prefix-checked)."""
import glob, json, os, runpy, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAT = os.path.join(ROOT, "Sources", "AIDiskKeeperUI", "Resources", "Localizable.xcstrings")
DEFAULT_PREFIXES = {
    "T37": ("apps.",), "T38": ("startup.",), "T40": ("storage.",), "T43": ("care.", "overview."),
    "T46": ("state.", "a11y."), "T47": ("menubar.",), "T48": ("menubar.glyph.a11y",), "T39b": ("devtools.",),
}


def entries(path):
    """Returns (full catalog key -> vi text, allowed prefixes or None)."""
    ns = runpy.run_path(path)
    out = {}
    for name, prefix in (("VI", ""), ("WHY", "protected.why.")):
        for k, v in ns.get(name, {}).items():
            out[prefix + k] = v
    stem = os.path.basename(path).split(".")[0]
    return out, ns.get("PREFIXES") or DEFAULT_PREFIXES.get(stem)


def write(cat):
    open(CAT, "w", encoding="utf-8").write(json.dumps(cat, indent=2, sort_keys=True, ensure_ascii=False, separators=(",", " : ")) + "\n")


def main(args):
    verify = bool(args) and args[0] == "--verify"
    paths = args[1:] if verify else args
    if verify and not paths:
        paths = sorted(glob.glob(os.path.join(ROOT, "scripts", "l10n", "*.vi.py")))
    if not paths:
        sys.exit(__doc__)
    cat = json.load(open(CAT, encoding="utf-8"))
    strings, errors, owner, changed = cat["strings"], [], {}, 0
    for path in paths:
        name = os.path.basename(path)
        ents, prefixes = entries(path)
        for key, vi in ents.items():
            if verify:
                if key in owner:
                    errors.append(f"{key}: in both {owner[key]} and {name}")
                owner[key] = name
                if prefixes and not key.startswith(tuple(prefixes)):
                    errors.append(f"{name}: {key} lacks an allowed prefix {tuple(prefixes)}")
            if key not in strings:
                errors.append(f"{name}: unknown key {key}")
                continue
            unit = strings[key].setdefault("localizations", {}).get("vi", {}).get("stringUnit", {})
            if verify:
                if unit.get("value") != vi:
                    errors.append(f"{name}: {key} catalog vi differs from the vi file (run scripts/l10n-regen.sh)")
            elif unit.get("value") == vi and unit.get("state") in ("translated", "needs_review"):
                continue
            else:
                strings[key]["localizations"]["vi"] = {"stringUnit": {"state": "needs_review", "value": vi}}
                changed += 1
    for e in errors:
        print("error:", e, file=sys.stderr)
    if errors:
        sys.exit(1)
    if verify:
        print(f"ok: {len(owner)} vi-file keys match the catalog")
    else:
        write(cat)
        print(f"applied: {changed} change(s)")


if __name__ == "__main__":
    main(sys.argv[1:])
