#!/bin/bash
# T-901: the unit that continues an install after a reboot. It was Type=oneshot: systemd counted the whole install as
# its start, held the boot open for it (36 min on the reference host), and when the install removed the unit and ran
# daemon-reload at the end, the start timeout came back and systemd killed the run, before "install finished" in one
# of two runs. Now Type=simple, and the last step logs "install finished" before it removes the unit.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
RESUME_UNIT=$SANDBOX/oif-resume.service; SELF=/opt/oif/oif
SEQ=$SANDBOX/seq; TLOG=$SEQ   # log lines and systemctl calls in one file, in the order they happen
systemctl() { echo "systemctl $*" >> "$SEQ"; }

install_resume_unit
ok_ grep -qx 'Type=simple' "$RESUME_UNIT"
no_ grep -q 'oneshot' "$RESUME_UNIT"
ok_ grep -qx "ExecStart=$SELF _resume" "$RESUME_UNIT"
grep -qx 'systemctl enable oif-resume.service' "$SEQ" || fail "the unit is enabled"

: > "$SEQ"
install_finished >/dev/null
eq "$(grep -n -e 'install finished' -e 'daemon-reload' "$SEQ" | cut -d: -f2- | sed 's/.*== //' | xargs)" \
   "install finished systemctl daemon-reload" "log first, then reload:"
no_ test -e "$RESUME_UNIT"

: > "$SEQ"
install_finished >/dev/null   # no unit (an install without a reboot): nothing to remove, no reload
no_ grep -q daemon-reload "$SEQ"
ok_ grep -q 'install finished' "$SEQ"
finish
