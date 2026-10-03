#!/usr/bin/env bash
# run_local_etcd_recovery_test.sh - end-to-end test of the Route 2a
# etcd <-> Jetpack failure-recovery handshake, on a single machine.
#
# Unlike run_local_etcd_3r.sh (one deptran process hosting all three replicas),
# this runs THREE deptran processes, each paired with one etcd node through its
# OWN signal directory:
#
#   etcd0 127.0.0.1 -+                        +- deptran h1 (s101, loc 0) + client
#                    | JM_SIGNAL_DIR=/tmp/jm-h1
#   etcd1 127.0.0.2 -+                        +- deptran h2 (s201, loc 1)
#                    | JM_SIGNAL_DIR=/tmp/jm-h2
#   etcd2 127.0.0.3 -+                        +- deptran h3 (s301, loc 2)
#                    | JM_SIGNAL_DIR=/tmp/jm-h3
#
# The per-pair signal directory is what makes this faithful: in a real
# deployment the signal file is machine-local, so only the Jetpack replica
# co-located with the NEW etcd leader ever observes a viewchange -> exactly one
# recovery coordinator. Sharing one /tmp across all six processes (as the
# single-process script necessarily does) would let every replica coordinate;
# Route 2a relies on the signal file being machine-local.
#
# Requires an etcd built with --leader viewbarrier:
#   scripts/build_etcd_patched.sh --leader viewbarrier
#
# Usage: scripts/run_local_etcd_recovery_test.sh [--duration N] [--no-failover]

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/local_deps_env.sh"

DURATION=25
DO_FAILOVER=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)    DURATION="$2"; shift 2 ;;
    --no-failover) DO_FAILOVER=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

ETCD_BIN="${ETCD_BIN:-$HOME/.local/bin/etcd}"
ETCDCTL="${ETCDCTL:-$HOME/.local/bin/etcdctl}"
SERVER_BIN="$ROOT/build/deptran_server"
LOG_DIR="${LOG_DIR:-/tmp/jetpack-recovery-test}"
IPS=(127.0.0.1 127.0.0.2 127.0.0.3)
PROCS=(h1 h2 h3)

for f in "$ETCD_BIN" "$ETCDCTL" "$SERVER_BIN"; do
  [[ -x "$f" ]] || { echo "missing executable: $f" >&2; exit 1; }
done

STAMP_FILE="$(dirname "$ETCD_BIN")/.etcd-jetpack-build"
STAMP="$(cat "$STAMP_FILE" 2>/dev/null || echo "UNPATCHED")"
echo "[test] etcd patch set: $STAMP"
case "$STAMP" in
  *viewbarrier*) ;;
  *) echo "[test] ERROR: this test needs an etcd built with --leader viewbarrier." >&2
     echo "[test]        run: scripts/build_etcd_patched.sh --leader viewbarrier" >&2
     exit 1 ;;
esac

rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
ETCD_PIDS=(); JP_PIDS=()

cleanup() {
  for p in "${JP_PIDS[@]:-}";   do [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; done
  for p in "${ETCD_PIDS[@]:-}"; do [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; done
  return 0
}
trap cleanup EXIT

# ---- 1. etcd cluster, one signal dir per node ----------------------------
CLUSTER="etcd0=http://127.0.0.1:2380,etcd1=http://127.0.0.2:2380,etcd2=http://127.0.0.3:2380"
echo "[test] starting 3-node etcd cluster (per-node signal dirs)"
for i in 0 1 2; do
  ip="${IPS[$i]}"; proc="${PROCS[$i]}"
  sigdir="/tmp/jm-${proc}"
  rm -rf "$sigdir" "/tmp/etcd-rt-${i}"; mkdir -p "$sigdir" "/tmp/etcd-rt-${i}"
  JM_SIGNAL_DIR="$sigdir" JM_SIGNAL_HOST="0.0.0.0" \
  "$ETCD_BIN" \
    --name "etcd${i}" \
    --listen-client-urls "http://${ip}:2379" \
    --advertise-client-urls "http://${ip}:2379" \
    --listen-peer-urls "http://${ip}:2380" \
    --initial-advertise-peer-urls "http://${ip}:2380" \
    --initial-cluster "$CLUSTER" \
    --initial-cluster-token "jetpack-rt" \
    --initial-cluster-state new \
    --data-dir "/tmp/etcd-rt-${i}" \
    --logger zap --log-level info \
    > "$LOG_DIR/etcd-${i}.log" 2>&1 &
  ETCD_PIDS+=($!)
  echo "  etcd${i} ${ip}:2379  signal_dir=$sigdir  pid=${ETCD_PIDS[$i]}"
done

for attempt in $(seq 1 40); do
  healthy=0
  for ip in "${IPS[@]}"; do
    "$ETCDCTL" endpoint health --endpoints="http://${ip}:2379" >/dev/null 2>&1 && healthy=$((healthy+1))
  done
  [[ "$healthy" -eq 3 ]] && break
  sleep 0.5
done
[[ "${healthy:-0}" -eq 3 ]] || { echo "[test] etcd cluster failed to form"; tail -20 "$LOG_DIR"/etcd-*.log; exit 1; }
echo "[test] etcd cluster healthy (3/3)"

echo "[test] startup-election viewchange lines (one per node that ever led):"
for proc in "${PROCS[@]}"; do
  line="$(grep -h '^etcd:viewchange' "/tmp/jm-${proc}/JM_Jetpack_0.0.0.0" 2>/dev/null | tail -1)"
  printf "    %-3s %s\n" "$proc" "${line:-<none>}"
done

# ---- 2. three deptran processes -----------------------------------------
echo "[test] starting 3 deptran processes (h1 also runs the client)"
for i in 0 1 2; do
  proc="${PROCS[$i]}"
  # h2/h3 have no client; WaitForShutdown returns quickly without one, so give
  # them a longer duration and let cleanup kill them.
  d="$DURATION"; [[ "$proc" != "h1" ]] && d=$(( DURATION * 5 ))
  JM_SIGNAL_DIR="/tmp/jm-${proc}" \
  "$SERVER_BIN" \
    -f "$ROOT/config/1c1s3r1p_wan.yml" \
    -f "$ROOT/config/none_etcd.yml" \
    -f "$ROOT/config/rw_fixed.yml" \
    -f "$ROOT/config/client_closed.yml" \
    -f "$ROOT/config/concurrent_1.yml" \
    -P "$proc" -d "$d" -r "$LOG_DIR" \
    > "$LOG_DIR/proc-${proc}.log" 2>&1 &
  JP_PIDS+=($!)
  echo "  $proc pid=${JP_PIDS[$i]}  signal_dir=/tmp/jm-${proc}"
done

# ---- 3. kill the etcd leader --------------------------------------------
if [[ "$DO_FAILOVER" -eq 1 ]]; then
  sleep 12
  leader_ip=$("$ETCDCTL" --endpoints="http://127.0.0.1:2379,http://127.0.0.2:2379,http://127.0.0.3:2379" \
      endpoint status -w simple 2>/dev/null | awk -F', ' '$5=="true"{print $1}' | sed 's|http://||;s|:2379||' | head -1)
  echo "[test] etcd leader = ${leader_ip:-unknown}; killing it"
  for i in 0 1 2; do
    if [[ "${IPS[$i]}" == "$leader_ip" ]]; then
      kill -9 "${ETCD_PIDS[$i]}" 2>/dev/null
      echo "  killed etcd${i} (was paired with ${PROCS[$i]})"
      echo "$leader_ip" > "$LOG_DIR/killed_leader_ip"
    fi
  done
fi

wait "${JP_PIDS[0]}" 2>/dev/null
echo "[test] h1 exited; logs in $LOG_DIR"
