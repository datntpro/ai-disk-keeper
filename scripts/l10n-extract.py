#!/usr/bin/env python3
"""Keeps Sources/AIDiskKeeperUI/Resources/Localizable.xcstrings in step with the `loc("key", "English")` calls.

Run with `python3 -I scripts/l10n-extract.py [--check | --sync | --dump]`. Needs Xcode selected (DEVELOPER_DIR).

It builds the UI target with the compiler's own `-emit-localized-strings` so each key's exact format string
(`%lld`, `%@`, `%lf`) is known, then pairs every record with the `loc("key",` text just before its location.

  --check  exit 1 on: key missing from the catalog, stale key, en text differing from code, a literal that is not
           inside loc() (hard-coded UI text), a key with conflicting defaults, a missing/empty vi value.
  --sync   add missing keys (vi = en, state "new"), mark removed keys "stale" (never auto-deleted), update en when
           the code default changed and flip vi to "needs_review".
  --dump   print "key<TAB>en format" for reviewers.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UI_SRC = os.path.join(ROOT, "Sources", "AIDiskKeeperUI")
CATALOG = os.path.join(UI_SRC, "Resources", "Localizable.xcstrings")
SCRATCH = os.path.join(ROOT, ".build", "l10n-build")
KEY_RE = re.compile(r'loc\(\s*"([^"]+)"\s*,\s*$')


def build():
    env = dict(os.environ)
    # Only fall back to the default Xcode when the selected developer dir is the Command Line Tools (no xcstringstool).
    if "DEVELOPER_DIR" not in env:
        selected = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True).stdout.strip()
        if "CommandLineTools" in selected or not selected:
            env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    # Force a recompile so every source emits its .stringsdata.
    subprocess.run(["rm", "-rf", SCRATCH], check=True)
    cmd = ["swift", "build", "--build-system", "swiftbuild", "--target", "AIDiskKeeperUI", "--scratch-path", SCRATCH,
           "-Xswiftc", "-emit-localized-strings", "-Xswiftc", "-emit-localized-strings-path",
           "-Xswiftc", os.path.join(ROOT, ".build", "l10n")]
    r = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout[-3000:] + r.stderr[-3000:])
        sys.exit("swift build failed")


def collect():
    """Returns (keys: {key: en_format}, errors: [str])."""
    keys, errors = {}, []
    found = []
    for base in (SCRATCH, os.path.join(ROOT, ".build", "l10n")):
        for dirpath, _, files in os.walk(base):
            found += [os.path.join(dirpath, f) for f in files if f.endswith(".stringsdata")]
    if not found:
        sys.exit("no .stringsdata produced; is the toolchain Xcode (not Command Line Tools)?")
    for path in sorted(found):
        data = json.load(open(path, encoding="utf-8"))
        src = data.get("source", "")
        if not src.startswith(UI_SRC + os.sep):
            continue
        entries = data.get("tables", {}).get("Localizable", [])
        if not entries:
            continue
        lines = open(src, encoding="utf-8").read().split("\n")
        rel = os.path.relpath(src, ROOT)
        for e in entries:
            line, col = e["location"]["startingLine"], e["location"]["startingColumn"]
            before = "\n".join(lines[max(0, line - 4):line - 1] + [lines[line - 1][:col - 1]])
            m = KEY_RE.search(before)
            if not m:
                errors.append(f"{rel}:{line}: user-facing literal outside loc(): {e['key']!r}")
                continue
            key, fmt = m.group(1), e["key"]
            if key in keys and keys[key] != fmt:
                errors.append(f"{rel}:{line}: key {key!r} has conflicting defaults: {keys[key]!r} vs {fmt!r}")
            keys.setdefault(key, fmt)
    return keys, errors


def load_catalog():
    with open(CATALOG, encoding="utf-8") as f:
        return json.load(f)


def unit(entry, lang):
    return entry.get("localizations", {}).get(lang, {}).get("stringUnit")


def check(keys, errors, cat):
    strings = cat["strings"]
    for k, fmt in sorted(keys.items()):
        if k not in strings:
            errors.append(f"catalog is missing key {k!r} (run --sync)")
            continue
        en = unit(strings[k], "en")
        if not en or en.get("value") != fmt:
            errors.append(f"{k}: en differs from code default (code {fmt!r}, catalog {en and en.get('value')!r})")
        vi = unit(strings[k], "vi")
        if not vi or not vi.get("value", "").strip():
            errors.append(f"{k}: missing vi value")
        elif vi.get("state") == "new":
            errors.append(f"{k}: vi still untranslated (state new)")
    for k in sorted(strings):
        if k not in keys:
            errors.append(f"catalog key {k!r} is not used by code (stale)")
    return errors


def sync(keys, cat):
    strings = cat["strings"]
    changed = 0
    for k, fmt in keys.items():
        if k not in strings:
            strings[k] = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": fmt}},
                                            "vi": {"stringUnit": {"state": "new", "value": fmt}}}}
            changed += 1
            continue
        entry = strings[k]
        entry.pop("extractionState", None)
        en = unit(entry, "en")
        if en is None or en["value"] != fmt:
            entry.setdefault("localizations", {})["en"] = {"stringUnit": {"state": "translated", "value": fmt}}
            vi = unit(entry, "vi")
            if vi and vi["state"] != "new":
                vi["state"] = "needs_review"
            changed += 1
    for k, entry in strings.items():
        if k not in keys and entry.get("extractionState") != "stale":
            entry["extractionState"] = "stale"
            changed += 1
    write_catalog(cat)
    print(f"synced: {changed} change(s), {len(keys)} keys")


def write_catalog(cat):
    cat["sourceLanguage"] = "en"
    cat["version"] = "1.0"
    text = json.dumps(cat, indent=2, sort_keys=True, ensure_ascii=False, separators=(",", " : "))
    with open(CATALOG, "w", encoding="utf-8") as f:
        f.write(text + "\n")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    if mode not in ("--check", "--sync", "--dump"):
        sys.exit(__doc__)
    build()
    keys, errors = collect()
    cat = load_catalog()
    if mode == "--dump":
        for k in sorted(keys):
            print(f"{k}\t{keys[k]}")
        return
    if mode == "--sync":
        for e in errors:
            print("error:", e, file=sys.stderr)
        if errors:
            sys.exit(1)
        sync(keys, cat)
        return
    errors = check(keys, errors, cat)
    for e in errors:
        print("error:", e, file=sys.stderr)
    if errors:
        sys.exit(1)
    print(f"ok: {len(keys)} keys, en + vi complete")


if __name__ == "__main__":
    main()
