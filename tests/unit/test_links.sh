#!/bin/bash
# Markdown links between files in the repository resolve (external links are not fetched: no network in tests).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

out=$(cd "$ROOT" && git ls-files '*.md' | python3 -c '
import os, re, sys
bad = []
for f in sys.stdin.read().split():
    text = re.sub(r"```.*?```|`[^`\n]*`", "", open(f, encoding="utf-8").read(), flags=re.S)  # code is not a link
    for target in re.findall(r"\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)", text):
        if re.match(r"[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
            continue                                                  # external, or a heading in the same file
        path = os.path.normpath(os.path.join(os.path.dirname(f), target.split("#")[0]))
        if not os.path.exists(path):
            bad.append(f"{f}: {target}")
print("\n".join(bad))
') || fail "link check did not run"
[ -z "$out" ] || fail "broken links:
$out"
finish
