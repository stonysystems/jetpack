#!/usr/bin/env bash
# build_etcd_patched.sh - build an etcd binary from source with the Jetpack
# patches in patches/ applied.
#
# aws_setup_script.sh and docker/etcd/Dockerfile use it, so the etcd they run
# writes the leader-change signal that Jetpack's recovery poller waits on
# (src/deptran/etcd/server.h).
#
# Usage:
#   scripts/build_etcd_patched.sh [options]
#
#   --version <tag>     etcd source tag to build            (default v3.5.13)
#   --leader <mode>     viewbarrier | signal | none         (default viewbarrier)
#   --lease-reads       also apply the ETCD_READ_ONLY_OPTION patch
#   --prefix <dir>      install etcd/etcdctl here           (default ~/.local/bin)
#   --src <dir>         scratch dir for source + build      (default ~/local/etcd-src)
#   --force             rebuild even if the binary is already current
#
# The two --leader modes are mutually exclusive by construction: both patch the
# same `if newLeader { ... }` block in server/etcdserver/server.go.
#
#   viewbarrier  Route 2a. Blocks the raft loop at the instant this node becomes
#                leader, before the first AppendEntries of the new term, until
#                the co-located Jetpack replica acks that it has paused. Carries
#                the real raft term + a per-boot nonce, so the recovery View gets
#                a non-zero view_id.
#   signal       The older mechanism: fire "etcd:primary_elected" and wait for
#                "jetpack:fastpath_stopped" in a goroutine. Does not block the
#                raft loop and carries no term.
#
# Patches are applied with `git apply` rather than GNU `patch`: the leader-signal
# hunk is rejected by GNU patch even when byte-correct, and `git apply` is what
# the patch headers were generated for.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ETCD_VERSION="v3.5.13"
LEADER_MODE="viewbarrier"
LEASE_READS=0
PREFIX="$HOME/.local/bin"
SRC_ROOT="$HOME/local/etcd-src"
FORCE=0
GO_VERSION="1.21.8"          # matches etcd v3.5.13's .go-version

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)     ETCD_VERSION="$2"; shift 2 ;;
    --leader)      LEADER_MODE="$2"; shift 2 ;;
    --lease-reads) LEASE_READS=1; shift ;;
    --prefix)      PREFIX="$2"; shift 2 ;;
    --src)         SRC_ROOT="$2"; shift 2 ;;
    --force)       FORCE=1; shift ;;
    -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$LEADER_MODE" in
  viewbarrier|signal|none) ;;
  *) echo "--leader must be viewbarrier|signal|none (got '$LEADER_MODE')" >&2; exit 2 ;;
esac

# ---- pick the patch set --------------------------------------------------
PATCHES=()
case "$LEADER_MODE" in
  viewbarrier) PATCHES+=("$ROOT/patches/etcd-jetpack-2a-viewbarrier-${ETCD_VERSION}.patch") ;;
  signal)      PATCHES+=("$ROOT/patches/etcd-leader-signal.patch") ;;
esac
[[ "$LEASE_READS" -eq 1 ]] && PATCHES+=("$ROOT/patches/etcd-lease-reads-${ETCD_VERSION}.patch")

for p in "${PATCHES[@]:-}"; do
  [[ -f "$p" ]] || { echo "missing patch: $p" >&2
                     echo "  (patches are version-pinned; regenerate for $ETCD_VERSION)" >&2
                     exit 1; }
done

if [[ ${#PATCHES[@]} -gt 0 ]] && ! command -v git >/dev/null 2>&1; then
  echo "git is required to apply the patches (GNU patch rejects the" >&2
  echo "leader-signal hunk even when it is byte-correct)." >&2
  exit 1
fi

# A build is identified by version + patch set, so switching modes rebuilds.
STAMP="${ETCD_VERSION}:${LEADER_MODE}:lease=${LEASE_READS}"
STAMP_FILE="$PREFIX/.etcd-jetpack-build"
if [[ "$FORCE" -eq 0 && -x "$PREFIX/etcd" && -f "$STAMP_FILE" ]] \
   && [[ "$(cat "$STAMP_FILE")" == "$STAMP" ]]; then
  echo "[etcd] already built and current: $STAMP"
  echo "[etcd] $PREFIX/etcd  ($("$PREFIX/etcd" --version | head -1))"
  exit 0
fi

echo "[etcd] building $ETCD_VERSION  leader=$LEADER_MODE  lease_reads=$LEASE_READS"

# ---- Go toolchain --------------------------------------------------------
GO_BIN="$(command -v go || true)"
if [[ -z "$GO_BIN" ]]; then
  GO_ROOT="$HOME/local/toolchain/go"
  if [[ ! -x "$GO_ROOT/bin/go" ]]; then
    echo "[etcd] no system Go; fetching go${GO_VERSION} into $GO_ROOT"
    mkdir -p "$(dirname "$GO_ROOT")"
    tmp="$(mktemp -d)"
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o "$tmp/go.tar.gz"
    tar -xzf "$tmp/go.tar.gz" -C "$(dirname "$GO_ROOT")"
    rm -rf "$tmp"
  fi
  export PATH="$GO_ROOT/bin:$PATH"
  GO_BIN="$GO_ROOT/bin/go"
fi
export GOPATH="${GOPATH:-$HOME/local/gopath}"
export GOCACHE="${GOCACHE:-$HOME/local/gocache}"
export GOFLAGS="${GOFLAGS:--mod=mod}"
echo "[etcd] using $($GO_BIN version)"

# ---- source --------------------------------------------------------------
mkdir -p "$SRC_ROOT"
TARBALL="$SRC_ROOT/etcd-${ETCD_VERSION}.tar.gz"
PRISTINE="$SRC_ROOT/etcd-${ETCD_VERSION#v}"
if [[ ! -d "$PRISTINE" ]]; then
  echo "[etcd] downloading source $ETCD_VERSION"
  curl -fsSL "https://github.com/etcd-io/etcd/archive/refs/tags/${ETCD_VERSION}.tar.gz" -o "$TARBALL"
  tar -xzf "$TARBALL" -C "$SRC_ROOT"
fi

# Always patch a throwaway copy so the pristine tree stays reusable and the
# patch set is applied exactly once (patches are not idempotent).
WORK="$SRC_ROOT/build-${LEADER_MODE}-lease${LEASE_READS}"
rm -rf "$WORK"
cp -r "$PRISTINE" "$WORK"

for p in "${PATCHES[@]:-}"; do
  echo "[etcd] applying $(basename "$p")"
  (cd "$WORK" && git apply --verbose "$p") || {
    echo "[etcd] FAILED to apply $(basename "$p") to $ETCD_VERSION" >&2; exit 1; }
done
[[ ${#PATCHES[@]} -eq 0 ]] && echo "[etcd] (no patches; plain $ETCD_VERSION build)"

# ---- build ---------------------------------------------------------------
echo "[etcd] compiling (this takes a few minutes on a cold Go cache)"
(cd "$WORK" && ./build.sh)

[[ -x "$WORK/bin/etcd" ]] || { echo "[etcd] build produced no bin/etcd" >&2; exit 1; }

mkdir -p "$PREFIX"
install -m 0755 "$WORK/bin/etcd"    "$PREFIX/etcd"
install -m 0755 "$WORK/bin/etcdctl" "$PREFIX/etcdctl"
echo "$STAMP" > "$STAMP_FILE"

echo "[etcd] installed to $PREFIX"
echo "[etcd] $("$PREFIX/etcd" --version | head -1)"
echo "[etcd] patch set: $STAMP"
