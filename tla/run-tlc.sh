#!/bin/bash
# Usage: ./run-tlc.sh <spec.tla> [extra TLC args...]
# Example: ./run-tlc.sh raft.tla
# Example: ./run-tlc.sh jetpack_raft.tla -workers 4

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPEC="$1"
shift || true

if [ -z "$SPEC" ]; then
    echo "Usage: $0 <spec.tla> [extra TLC args...]"
    exit 1
fi

# Derive cfg from spec name if it exists
CFG="${SPEC%.tla}.cfg"

# Build docker image if needed
docker build -t tlaplus "$SCRIPT_DIR" 2>/dev/null

TLC_ARGS=()
if [ -f "$SCRIPT_DIR/$CFG" ]; then
    TLC_ARGS+=("-config" "$CFG")
fi
TLC_ARGS+=("$SPEC")
TLC_ARGS+=("$@")

docker run --rm --privileged -v "$SCRIPT_DIR":/tla tlaplus tlc2.TLC -nowarning -deadlock "${TLC_ARGS[@]}"
