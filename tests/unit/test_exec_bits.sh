#!/bin/bash
# T-901: the scripts the guides run as ./path are stored executable in git; tests/host/verify-clean.sh was not, so
# "./tests/host/verify-clean.sh" (guide 09) failed with Permission denied on a fresh clone.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
bad=$(git -C "$ROOT" ls-files -s -- oif 'tests/host/*.sh' 'tests/lab/*.sh' 'tools/*.sh' | awk '$1 != "100755" {print $4}' | xargs)
eq "$bad" "" "scripts stored without the executable bit:"
finish
