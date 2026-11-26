#!/usr/bin/env python3
"""Merges a {key: vi text} Python dict file (variable VI or WHY) into Localizable.xcstrings as state needs_review.
Usage: python3 -I scripts/l10n-apply.py <file.py> [<file.py> ...]   (maintainer helper, not run in CI)"""
import json, os, runpy, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAT = os.path.join(ROOT, "Sources", "AIDiskKeeperUI", "Resources", "Localizable.xcstrings")
cat = json.load(open(CAT, encoding="utf-8"))
for path in sys.argv[1:]:
    ns = runpy.run_path(path)
    for name, prefix in (("VI", ""), ("WHY", "protected.why.")):
        for k, v in ns.get(name, {}).items():
            key = prefix + k
            if key not in cat["strings"]:
                print("unknown key", key); continue
            cat["strings"][key]["localizations"]["vi"] = {"stringUnit": {"state": "needs_review", "value": v}}
open(CAT, "w", encoding="utf-8").write(json.dumps(cat, indent=2, sort_keys=True, ensure_ascii=False, separators=(",", " : ")) + "\n")
