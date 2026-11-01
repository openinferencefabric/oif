#!/bin/bash
# T-003: do oif's patches still apply to the upstream source they are pinned to? Downloads the Run:ai and KAI Scheduler
# source archives named in versions.env (cached in tests/.cache), checks their checksums, and applies every patch in
# order with 'git apply', as the build Jobs do. Needs network the first time; writes nothing outside tests/.cache.
#   tests/check-patches.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=../versions.env
. ./versions.env
cache=tests/.cache; work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$cache"
fail=0

check() {   # name url sha256 archive-top-folder patch-folder
  local tgz=$cache/$1.tgz n=0
  echo "== $1"
  if [ ! -s "$tgz" ] || [ "$(sha256sum "$tgz" | cut -d' ' -f1)" != "$3" ]; then
    curl -fsSL --retry 3 -o "$tgz.part" "$2" && mv "$tgz.part" "$tgz" || { rm -f "$tgz.part"; echo "   FAIL download $2"; fail=1; return; }
  fi
  [ "$(sha256sum "$tgz" | cut -d' ' -f1)" = "$3" ] || { echo "   FAIL checksum of $2 (versions.env)"; fail=1; return; }
  tar -xzf "$tgz" -C "$work" || { echo "   FAIL unpack $tgz"; fail=1; return; }
  for p in "$5"/*.patch; do
    if git -C "$work/$4" apply "$PWD/$p" 2>"$work/err"; then
      echo "   ok   ${p##*/}"; n=$((n + 1))
    else
      echo "   FAIL ${p##*/}"; sed 's/^/        /' "$work/err"; fail=1
    fi
  done
  [ "$n" -gt 0 ] || { echo "   FAIL no patches in $5"; fail=1; }
}

check "run-ai-$RUNAI_VERSION" "https://codeload.github.com/dsx-ai-factory/run-ai/tar.gz/refs/tags/$RUNAI_VERSION" \
  "$RUNAI_SOURCE_SHA256" "run-ai-$RUNAI_VERSION" "patches/runai/$RUNAI_VERSION"
check "kai-$KAI_VERSION" "https://codeload.github.com/kai-scheduler/KAI-scheduler/tar.gz/refs/tags/$KAI_VERSION" \
  "$KAI_SOURCE_SHA256" "KAI-Scheduler-${KAI_VERSION#v}" "patches/kai/$KAI_VERSION"

[ $fail = 0 ] && echo "all patches apply" || echo "PATCH CHECK FAILED"
exit $fail
