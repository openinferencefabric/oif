# shellcheck shell=bash
# Shared by the image build scripts (images/*/build.sh).

# push_image CT IMAGE LOG: push IMAGE (repo:tag) with CT (docker or podman), the push's output to LOG; print the
# digest the registry now serves for it (sha256:...). Podman recompresses the layers on push and writes a new
# manifest, but `podman image inspect` keeps its local manifest's digest; only --digestfile gives the pushed one.
push_image() {
  local ct=$1 img=$2 log=$3 df
  if [ "$(basename "$ct")" = podman ]; then
    df=$(mktemp)
    "$ct" push --digestfile "$df" "$img" > "$log" 2>&1 || { rm -f "$df"; return 1; }
    cat "$df"; rm -f "$df"
  else
    "$ct" push "$img" > "$log" 2>&1 || return 1
    "$ct" image inspect "$img" --format '{{range .RepoDigests}}{{println .}}{{end}}' | grep "^${img%:*}@" | head -1 | sed 's/.*@//'
  fi
}
