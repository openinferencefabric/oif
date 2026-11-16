#!/bin/bash
# B-1a: one oif bench per node (ADR-009: one GPU under load at a time; the server listens on one fixed port). In B-1
# a second run started while the first was between points and removed its server, losing 6 points. A second run is
# now refused with the PID of the run that holds the lock; the lock is free again when that run ends.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
command -v flock >/dev/null || { echo "      SKIP: no flock here (CI runs it)"; finish; }
export BENCH_LOCK=$SANDBOX/oif-bench.lock
bench() { bash "$ROOT/bench/oif-bench.sh" --profile quick 2>&1; }

# another run holds the lock: refused, and told which process
( exec 8>"$BENCH_LOCK"; flock 8; echo 4242 >&8; sleep 5 ) & holder=$!
sleep 1
out=$(bench)
grep -q "another oif bench is running on this node (PID 4242)" <<< "$out" || fail "second run refused with the holder's PID: $out"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# lock free: the run goes past the lock (and stops at the next check, sudo, when the test is not root)
out=$(bench)
grep -q "another oif bench" <<< "$out" && fail "a free lock refused the run: $out"
[ "$(id -u)" = 0 ] || grep -q "run with sudo" <<< "$out" || fail "past the lock: $out"
finish
