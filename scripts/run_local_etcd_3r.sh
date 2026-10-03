#!/usr/bin/env bash
# run_local_etcd_3r.sh - bring up a 3-node etcd cluster and a 3-replica Jetpack
# deployment on a single machine, all on loopback.
#
# Mirrors what docker/etcd/run-etcd-test.sh does inside a container, but runs
# straight on the host so it works without Docker.
#
#   etcd0 127.0.0.1:2379   etcd1 127.0.0.2:2379   etcd2 127.0.0.3:2379
#   deptran s101/s201/s301 + client c01, all in ONE process (-P localhost)
#
# Usage:
#   scripts/run_local_etcd_3r.sh [--duration N] [--failover] [--keep-etcd]
#
#   --failover   also kill the etcd leader mid-run.
#
# CAVEAT: all six processes share one /tmp, so every replica sees every etcd
# node's signal. That breaks the machine-local property Route 2a relies on to
# elect a single recovery coordinator, so --failover here will show *several*
# replicas coordinating at once. Use scripts/run_local_etcd_recovery_test.sh
# for a faithful recovery test - it gives each etcd/deptran pair its own
# JM_SIGNAL_DIR. This script is for throughput/smoke runs.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/local_deps_env.sh"

DURATION=20
DO_FAILOVER=0
KEEP_ETCD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --failover) DO_FAILOVER=1; shift ;;
    --keep-etcd) KEEP_ETCD=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

ETCD_BIN="${ETCD_BIN:-$HOME/.local/bin/etcd}"
ETCDCTL="${ETCDCTL:-$HOME/.local/bin/etcdctl}"
SERVER_BIN="$ROOT/build/deptran_server"
LOG_DIR="${LOG_DIR:-/tmp/jetpack-local-etcd}"
IPS=(127.0.0.1 127.0.0.2 127.0.0.3)

for f in "$ETCD_BIN" "$ETCDCTL" "$SERVER_BIN"; do
  [[ -x "$f" ]] || { echo "missing executable: $f" >&2; exit 1; }
done

# Say up front which etcd this is: a vanilla binary writes no leader-change
# signal at all, so --failover would silently prove nothing.
STAMP_FILE="$(dirname "$ETCD_BIN")/.etcd-jetpack-build"
if [[ -f "$STAMP_FILE" ]]; then
  echo "[local] etcd patch set: $(cat "$STAMP_FILE")"
else
  echo "[local] WARNING: $ETCD_BIN has no Jetpack patch stamp - looks like a"
  echo "[local]          vanilla binary. Recovery will NOT trigger."
  echo "[local]          Build one with: scripts/build_etcd_patched.sh --leader signal"
fi

rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"

cleanup() {
  [[ -n "${JETPACK_PID:-}" ]] && kill -9 "$JETPACK_PID" 2>/dev/null
  if [[ "$KEEP_ETCD" -eq 0 ]]; then
    for p in "${ETCD_PIDS[@]:-}"; do [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; done
  fi
  return 0
}
trap cleanup EXIT

# ---- 1. etcd cluster ------------------------------------------------------
echo "[local] starting 3-node etcd cluster"
CLUSTER="etcd0=http://127.0.0.1:2380,etcd1=http://127.0.0.2:2380,etcd2=http://127.0.0.3:2380"
ETCD_PIDS=()
for i in 0 1 2; do
  ip="${IPS[$i]}"
  rm -rf "/tmp/etcd-local-${i}"; mkdir -p "/tmp/etcd-local-${i}"
  "$ETCD_BIN" \
    --name "etcd${i}" \
    --listen-client-urls "http://${ip}:2379" \
    --advertise-client-urls "http://${ip}:2379" \
    --listen-peer-urls "http://${ip}:2380" \
    --initial-advertise-peer-urls "http://${ip}:2380" \
    --initial-cluster "$CLUSTER" \
    --initial-cluster-token "jetpack-local" \
    --initial-cluster-state new \
    --data-dir "/tmp/etcd-local-${i}" \
    --logger zap --log-level info \
    > "$LOG_DIR/etcd-${i}.log" 2>&1 &
  ETCD_PIDS+=($!)
  echo "  etcd${i} ${ip}:2379 pid=${ETCD_PIDS[$i]}"
done

for attempt in $(seq 1 40); do
  healthy=0
  for ip in "${IPS[@]}"; do
    "$ETCDCTL" endpoint health --endpoints="http://${ip}:2379" >/dev/null 2>&1 && healthy=$((healthy+1))
  done
  [[ "$healthy" -eq 3 ]] && break
  sleep 0.5
done
[[ "${healthy:-0}" -eq 3 ]] || { echo "[local] etcd cluster failed to form"; tail -20 "$LOG_DIR"/etcd-*.log; exit 1; }
echo "[local] etcd cluster healthy (3/3)"
"$ETCDCTL" --endpoints="http://127.0.0.1:2379" put JetPack/leader initial >/dev/null 2>&1

# The signal file is machine-local and append-only; a leftover line from an
# earlier run would otherwise fire a spurious recovery at startup.
rm -f /tmp/JM_Jetpack_* 2>/dev/null || true

# ---- 2. Jetpack -----------------------------------------------------------
echo "[local] starting Jetpack (3 replicas + 1 client, single process)"
"$SERVER_BIN" \
  -f "$ROOT/config/1c1s3r1p.yml" \
  -f "$ROOT/config/none_etcd.yml" \
  -f "$ROOT/config/rw_fixed.yml" \
  -f "$ROOT/config/client_closed.yml" \
  -f "$ROOT/config/concurrent_1.yml" \
  -P localhost \
  -d "$DURATION" \
  -r "$LOG_DIR" \
  > "$LOG_DIR/proc-localhost.log" 2>&1 &
JETPACK_PID=$!
echo "  deptran_server pid=$JETPACK_PID"

if [[ "$DO_FAILOVER" -eq 1 ]]; then
  sleep 5
  leader_ip=$("$ETCDCTL" --endpoints="http://127.0.0.1:2379,http://127.0.0.2:2379,http://127.0.0.3:2379" \
      endpoint status -w simple 2>/dev/null | awk -F', ' '$5=="true"{print $1}' | sed 's|http://||;s|:2379||' | head -1)
  echo "[local] etcd leader = ${leader_ip:-unknown}; killing it"
  for i in 0 1 2; do
    [[ "${IPS[$i]}" == "$leader_ip" ]] && kill -9 "${ETCD_PIDS[$i]}" 2>/dev/null && echo "  killed etcd${i}"
  done
  echo "failure:failure_triggered" > /tmp/JM_Jetpack_failure_triggered
fi

wait "$JETPACK_PID"; rc=$?
echo "[local] deptran_server exited rc=$rc"
echo "[local] logs in $LOG_DIR"
exit $rc
