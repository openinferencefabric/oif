#!/bin/bash
# Grafana dashboards: valid JSON, and every query (panels and variables) reads only the vendor-neutral oif:* series.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

python3 - "$ROOT"/platform/observability/dashboards/*.json <<'PY' || fail "dashboards: invalid JSON or series outside oif:*"
import json, os, re, sys
KEYWORDS = {"and", "or", "unless", "bool", "offset", "group_left", "group_right"}
def queries(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in ("expr", "query", "definition") and isinstance(v, str):
                yield v
            elif k == "query" and isinstance(v, dict) and isinstance(v.get("query"), str):
                yield v["query"]
            else:
                yield from queries(v)
    elif isinstance(o, list):
        for x in o:
            yield from queries(x)
failed = False
for f in sys.argv[1:]:
    try:
        dash = json.load(open(f, encoding="utf-8"))
    except ValueError as e:
        print(f"      {os.path.basename(f)}: invalid JSON: {e}"); failed = True; continue
    bad = set()
    for q in queries(dash):
        q = re.sub(r'"(\\.|[^"\\])*"', "", q)                                       # strings, label values
        q = re.sub(r"\{[^}]*\}|\[[^\]]*\]", "", q)                                  # label matchers, ranges
        q = re.sub(r"\b(by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", "", q)  # label lists
        q = re.sub(r"label_values\(\s*([^,)]+)(,[^)]*)?\)", r"\1", q)              # variable: metric, label
        for m in re.finditer(r"[A-Za-z_:][\w:]*", q):
            name = m.group()
            if q[m.end():].lstrip().startswith("(") or name in KEYWORDS or name.startswith("oif:"):
                continue                                                            # a function, keyword, or oif:*
            bad.add(name)
    if bad:
        print(f"      {os.path.basename(f)}: series outside oif:*: {', '.join(sorted(bad))}"); failed = True
sys.exit(failed)
PY
finish
