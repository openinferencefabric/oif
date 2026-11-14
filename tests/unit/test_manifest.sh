#!/bin/bash
# Every recorded change is reversed by replay_manifest, newest first, leaving files as they were.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
S=$SANDBOX/host; mkdir -p "$S/etc"

printf 'original line\n' > "$S/etc/existing.conf"

# changes, as stages make them
put_file "$S/etc/new.conf" "new file"                       # FILE
put_file "$S/etc/existing.conf" "changed by oif"            # RESTORE
mkdir -p "$S/data/x"; rec "DATADIR $S/data"
rec "PKG example-package"; rec "PKG example-package"

eq "$(grep -c '^PKG ' "$MANIFEST")" 1 "package recorded once:"
eq "$(cat "$S/etc/existing.conf")" "changed by oif" "file changed:"

# plan is read-only and describes every record
before=$(cat "$MANIFEST")
out=$(tac "$MANIFEST" | describe_records)
eq "$(cat "$MANIFEST")" "$before" "describe_records is read-only:"
echo "$out" | grep -q "delete file $S/etc/new.conf" || fail "plan lists the new file"
echo "$out" | grep -q "restore $S/etc/existing.conf" || fail "plan lists the restore"

# replay: everything back as it was
teardown_example() { touch "$SANDBOX/teardown-ran"; }
register_teardown example; rec "TEARDOWN example"
replay_manifest >/dev/null
[ -e "$SANDBOX/teardown-ran" ] || fail "registered teardown ran"
[ -e "$S/etc/new.conf" ] && fail "new file removed"
eq "$(cat "$S/etc/existing.conf")" "original line" "changed file restored:"
[ -e "$S/data" ] && fail "data folder removed"

# stages run once
n=0; stage_counter() { n=$((n + 1)); }
stage counter; stage counter
eq "$n" 1 "stage runs once:"

# a stage pinned to a version runs again when the version changes, then once more not at all
m=0; stage_widget() { m=$((m + 1)); }
WIDGET_VERSION=v1; register_stage widget WIDGET_VERSION
touch "$DONE/widget"                      # marker from before the stage was pinned (empty)
stage widget; eq "$m" 1 "pinned stage runs when its marker has no version:"
stage widget; eq "$m" 1 "and not again for the same version:"
WIDGET_VERSION=v2; stage widget; eq "$m" 2 "a new version runs it again:"
eq "$(cat "$DONE/widget")" v2 "marker holds the version:"
finish
