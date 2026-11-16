#!/bin/bash
# The image build scripts print the digest to pin in versions.env after --push. It must be the digest the registry
# serves: podman recompresses the layers on push and writes a new manifest, while `podman image inspect` keeps showing
# its local manifest's digest (S-5: the pin from RepoDigests got "manifest unknown"). Docker's RepoDigests is the
# registry's. Fake docker and podman stand in for both.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=../../images/lib.sh
. "$ROOT/images/lib.sh"
img=ghcr.io/example/app:v1
bin=$SANDBOX/bin; mkdir -p "$bin"
cat > "$bin/podman" <<'EOF'
#!/bin/bash
case $1 in
  push) shift; [ "${FAKE_PUSH_FAILS:-0}" = 1 ] && { echo "denied" >&2; exit 125; }
        if [ "$1" = --digestfile ]; then printf 'sha256:pushed' > "$2"; fi; echo "Writing manifest to image destination" ;;
  image) echo "ghcr.io/example/app@sha256:local" ;;    # podman: the local manifest, not the pushed one
esac
EOF
cat > "$bin/docker" <<'EOF'
#!/bin/bash
case $1 in
  push) [ "${FAKE_PUSH_FAILS:-0}" = 1 ] && { echo "denied" >&2; exit 1; }; echo "v1: digest: sha256:pushed size: 1234" ;;
  image) echo "ghcr.io/example/app@sha256:pushed" ;;   # docker: the registry's
esac
EOF
chmod +x "$bin/podman" "$bin/docker"

eq "$(push_image "$bin/podman" "$img" "$SANDBOX/p.log")" "sha256:pushed" "podman: the digest the registry serves:"
eq "$(push_image "$bin/docker" "$img" "$SANDBOX/d.log")" "sha256:pushed" "docker: the digest the registry serves:"
grep -q "Writing manifest" "$SANDBOX/p.log" || fail "the push's output goes to the log"
FAKE_PUSH_FAILS=1 no_ push_image "$bin/podman" "$img" "$SANDBOX/f.log"
grep -q denied "$SANDBOX/f.log" || fail "a failed push leaves its error in the log"
finish
