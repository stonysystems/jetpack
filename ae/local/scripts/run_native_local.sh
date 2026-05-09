#!/usr/bin/env bash
# ae/local/scripts/run_native_local.sh
#
# Run one Jetpack benchmark point on the local Docker host using
# single-process mode (`-P localhost`), no SSH, no cluster setup.
# Used by ae/local/run.sh phase_exp0_native / phase_exp1 / phase_exp2
# to cover the 6 protocols that don't have a backend service:
#   - Group A native: raft, copilot, mencius
#   - Group B baselines: curp, swiftpaxos, epaxos
#
# How it works:
#   - Reuses the jetpack-etcd Docker image as the runtime
#     (it bundles deptran_server + all third-party libs).
#   - Overrides the entrypoint so the embedded etcd does NOT start;
#     we just run deptran_server directly with the requested config.
#   - Single-process mode means all 5 replicas + 1 client run as
#     threads in the same process. Inter-replica WAN delay comes from
#     the `WAN_DELAY_MS` env var (software-injected, not tc/netem).
#
# Usage:
#   run_native_local.sh <proto_cfg> <workload_cfg> <conc_cfg> <mode> <label> <out_dir>
#
# Example:
#   run_native_local.sh rule_raft.yml rw_1000000.yml concurrent_150.yml 101 \
#                       rule_raft-c150-fp101 ae/output/.../exp0/
#
# Requirements:
#   - Docker image `jetpack-etcd` already built (the AE wrapper builds
#     it as part of `--phase build`).

set -euo pipefail

PROTO_CFG="${1:?proto_cfg required}"
WORKLOAD_CFG="${2:?workload_cfg required}"
CONC_CFG="${3:?conc_cfg required}"
MODE="${4:?mode required}"
LABEL="${5:?label required}"
OUT_DIR="${6:?out_dir required}"

DURATION="${TEST_DURATION:-30}"
LATENCY_MS="${WAN_DELAY_MS:-20}"
IMAGE="${JETPACK_IMAGE:-jetpack-etcd}"
SITE_CFG="${SITE_CFG:-1c1s5r1p.yml}"
CLIENT_CFG="${CLIENT_CFG:-client_closed.yml}"

mkdir -p "$OUT_DIR"
RES_FILE="$OUT_DIR/${LABEL}.res"

# Confirm the image is present; otherwise the docker run below would
# silently try to pull from Docker Hub (which doesn't have it).
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[ERROR] Docker image $IMAGE not found. Build it first via:" >&2
    echo "        ./ae/reproduce_local.sh --phase build" >&2
    exit 1
fi

# Validate required configs exist in the AE-frozen config dir.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"     # ae/local/
CONFIG_DIR="$LOCAL_DIR/config"

for cfg in "$PROTO_CFG" "$SITE_CFG" "$WORKLOAD_CFG" "$CLIENT_CFG" "$CONC_CFG"; do
    if [[ ! -f "$CONFIG_DIR/$cfg" ]]; then
        echo "[ERROR] Missing config: $CONFIG_DIR/$cfg" >&2
        echo "        Required for label=$LABEL" >&2
        exit 2
    fi
done

# The image's /jetpack/config is from build time — we override it with
# the AE-frozen config dir to keep config under our control.
docker run --rm \
    -v "$CONFIG_DIR:/jetpack/config:ro" \
    -v "$OUT_DIR:/output" \
    -e WAN_DELAY_MS="$LATENCY_MS" \
    -e LD_LIBRARY_PATH=/usr/local/lib \
    --entrypoint bash \
    "$IMAGE" -c "
        ulimit -n 65536 2>/dev/null || true
        cd /jetpack
        timeout $((DURATION + 60)) ./build/deptran_server \
            -f /jetpack/config/$PROTO_CFG \
            -f /jetpack/config/$SITE_CFG \
            -f /jetpack/config/$WORKLOAD_CFG \
            -f /jetpack/config/$CLIENT_CFG \
            -f /jetpack/config/$CONC_CFG \
            -d $DURATION -m $MODE -P localhost \
            > /output/${LABEL}.res 2>&1
        echo \"exit=\$?\" >> /output/${LABEL}.res
    " || {
    echo "[WARN] $LABEL: docker run failed (see $RES_FILE)" >&2
    exit 1
}

# Lightweight pass/fail check on the .res
if grep -q "Mid throughput is" "$RES_FILE"; then
    echo "[OK]   $LABEL"
    exit 0
else
    echo "[FAIL] $LABEL — no Mid throughput in $RES_FILE" >&2
    exit 1
fi
