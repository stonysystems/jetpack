#!/bin/bash
# run_akkio_exp.sh — Akkio-style 4-variant etcd latency experiment.
#
# 5 zoo hosts; etcd primary on zoo1. Clients split 46/42/10/2/0 across
# zoo1..zoo5; each client site uses concurrent_20 + open-loop (max_undone=20).
# Workload: rw_akkio.yml (50/50 R/W, uniform over 1M keys).
#
# Four variants:
#   V1-raw            raw etcd; no batch; no lease reads  (stock etcd default)
#   V2-batch          raw etcd; client-side Txn batching (size=16, timeout=5 ms)
#   V3-lease          raw etcd; lease-based linearizable reads (ETCD_READ_ONLY_OPTION=lease)
#   V4-jetpack-etcd   Jetpack + etcd (merged-RPC variant, pool opts on)
#
# Layout:
#   results/<DATE>-akkio-etcd/
#     log/
#       V1-raw/<per-host res/csv/cpustat>
#       V2-batch/...
#       V3-lease/...
#       V4-jetpack-etcd/...
#       etcd-*.log                (raw etcd server logs per variant)
#     settings.md                 (full settings incl. commit hashes)
#     summary.md                  (populated by merge_latency_csv.py)
#
# Usage:
#   bash scripts/run_akkio_exp.sh [<RDIR override>]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DATE="$(date +%Y-%m-%d)"
EXP_NAME="akkio-etcd"
RDIR="${1:-${REPO_DIR}/results/${DATE}-${EXP_NAME}}"
LOG_DIR="${RDIR}/log"
mkdir -p "$LOG_DIR"

IPS=(130.245.173.101 130.245.173.102 130.245.173.103 130.245.173.104 130.245.173.105)
NAMES=(zoo1 zoo2 zoo3 zoo4 zoo5)
ZOO_DIR="/home/users/ztang/janus"
DURATION=30
TIMEOUT_SEC=180

# Akkio client layout 46/42/10/2/0 (100 client sites).
CLIENT_CFG="$(bash "$SCRIPT_DIR/gen_akkio_client_config.sh" 46 42 10 2 0 | tail -1)"
CLIENT_CFG_REL="$(basename "$CLIENT_CFG")"
CONC_YML="concurrent_20.yml"
OPEN_YML="client_open_akkio.yml"
BENCH_YML="rw_akkio.yml"

echo "=== Akkio etcd experiment ==="
echo "RDIR        = $RDIR"
echo "Client cfg  = $CLIENT_CFG_REL"
echo "Conc / open = $CONC_YML / $OPEN_YML"
echo "Bench       = $BENCH_YML"

# --------- etcd cluster management ---------

start_etcd_cluster() {
  local ro_option="$1"      # "safe" or "lease"
  local tag="$2"            # for log filenames under LOG_DIR

  local cluster=""
  for i in "${!IPS[@]}"; do
    if [ $i -ne 0 ]; then cluster+=","; fi
    cluster+="${NAMES[$i]}=http://${IPS[$i]}:2380"
  done

  echo "[etcd:${tag}] stopping any existing etcd..."
  for i in "${!IPS[@]}"; do
    ssh -o ConnectTimeout=5 "ztang@${IPS[$i]}" "pkill -9 etcd 2>/dev/null; rm -rf /tmp/etcd-${NAMES[$i]}.etcd" &>/dev/null &
  done
  wait
  sleep 2

  echo "[etcd:${tag}] starting 5-node cluster with ETCD_READ_ONLY_OPTION=${ro_option}..."
  for i in "${!IPS[@]}"; do
    local ip="${IPS[$i]}"
    local name="${NAMES[$i]}"
    ssh -o ConnectTimeout=5 "ztang@$ip" "nohup env ETCD_READ_ONLY_OPTION=${ro_option} \$HOME/.local/bin/etcd \
      --name=${name} \
      --data-dir=/tmp/etcd-${name}.etcd \
      --listen-peer-urls=http://${ip}:2380 \
      --initial-advertise-peer-urls=http://${ip}:2380 \
      --listen-client-urls=http://${ip}:2379,http://127.0.0.1:2379 \
      --advertise-client-urls=http://${ip}:2379 \
      --initial-cluster-token=jetpack-etcd \
      --initial-cluster=${cluster} \
      --initial-cluster-state=new \
      --logger=zap --log-level=info \
      > /tmp/etcd-${name}.log 2>&1 &" &
  done
  wait
  sleep 3

  # Copy etcd server logs into the result dir for the record.
  for i in "${!IPS[@]}"; do
    scp "ztang@${IPS[$i]}:/tmp/etcd-${NAMES[$i]}.log" "$LOG_DIR/etcd-${tag}-${NAMES[$i]}.log" &>/dev/null &
  done
  wait

  # Liveness probe.
  local bad=0
  for i in "${!IPS[@]}"; do
    if ! ssh -o ConnectTimeout=5 "ztang@${IPS[$i]}" "\$HOME/.local/bin/etcdctl --endpoints=http://${IPS[$i]}:2379 endpoint health" 2>&1 | head -1 | grep -q "is healthy"; then
      echo "[etcd:${tag}] ${NAMES[$i]}: UNHEALTHY"
      bad=$((bad+1))
    fi
  done
  if [ "$bad" -gt 0 ]; then
    echo "[etcd:${tag}] WARNING: $bad/5 nodes unhealthy after start (continuing)"
  fi
}

stop_etcd_cluster() {
  echo "[etcd] stopping cluster..."
  for i in "${!IPS[@]}"; do
    ssh -o ConnectTimeout=5 "ztang@${IPS[$i]}" "pkill -9 etcd 2>/dev/null" &>/dev/null &
  done
  wait
  sleep 1
}

# --------- deptran launch (one variant) ---------

run_deptran_variant() {
  local name="$1"          # V1-raw / V2-batch / V3-lease / V4-jetpack-etcd
  local mode_yml="$2"      # e.g. none_etcd.yml / none_etcd_batch.yml / rule_etcd.yml
  local mode_flag="$3"     # -m value (0 for none_etcd, 100 for rule_etcd typically)
  local variant_dir="$LOG_DIR/${name}"
  mkdir -p "$variant_dir"
  local label="${name}"

  # Clean up old deptran processes.
  for i in "${!IPS[@]}"; do
    ssh "ztang@${IPS[$i]}" "pkill -9 deptran_server 2>/dev/null; rm -f /tmp/JM_*" &>/dev/null &
  done
  wait
  sleep 3

  # Clear the leader's recent_csv dump location.
  ssh "ztang@${IPS[0]}" "mkdir -p ${ZOO_DIR}/results/recent_csv && rm -f ${ZOO_DIR}/results/recent_csv/*" &>/dev/null

  # CPU monitors, 1 Hz for (DURATION+15)s, on each host.
  echo "[${label}] starting per-host cpu monitors..."
  local cpu_dur=$((DURATION + 15))
  local cpu_script='
DURATION='"$cpu_dur"'
for t in $(seq 1 $DURATION); do
    ts=$(date +%s)
    echo "T=$ts"
    head -66 /proc/stat | grep -E "^cpu"
    sleep 1
done
'
  for i in "${!IPS[@]}"; do
    ssh "ztang@${IPS[$i]}" "$cpu_script" > "$variant_dir/${label}-${NAMES[$i]}-cpustat.txt" 2>&1 &
  done
  sleep 1

  # Server command. Keep SERVER_CORE_ID=17 pthread pin convention.
  local SERVER_CMD="export LD_LIBRARY_PATH=${ZOO_DIR}/build/docker_libs:\${HOME}/local/lib:\${LD_LIBRARY_PATH}; export WAN_DELAY_MS=20; export SERVER_CORE_ID=17; cd $ZOO_DIR && ${ZOO_DIR}/build/docker_libs/ld-linux-x86-64.so.2 build/deptran_server -f config/${mode_yml} -f config/${OPEN_YML} -f config/${CLIENT_CFG_REL} -f config/${BENCH_YML} -f config/${CONC_YML} -m ${mode_flag} -d ${DURATION}"

  echo "[${label}] launching deptran on 5 hosts (mode_yml=${mode_yml} -m ${mode_flag})..."
  declare -a pids
  for i in "${!IPS[@]}"; do
    local run_name="${label}-${NAMES[$i]}"
    local out="$variant_dir/${run_name}.res"
    timeout "${TIMEOUT_SEC}s" \
      ssh "ztang@${IPS[$i]}" "${SERVER_CMD} -P ${NAMES[$i]} -N ${run_name}" \
      > "$out" 2>&1 &
    pids[$i]=$!
  done
  for i in "${!pids[@]}"; do
    local pid=${pids[$i]}
    if wait "$pid"; then
      echo "[${label}] ${NAMES[$i]} completed."
    else
      local status=$?
      if [ $status -eq 124 ]; then
        echo "[${label}] ${NAMES[$i]} TIMED OUT."
      else
        echo "[${label}] ${NAMES[$i]} exit code $status."
      fi
    fi
  done

  # Cleanup.
  for i in "${!IPS[@]}"; do
    ssh "ztang@${IPS[$i]}" "pkill -9 deptran_server" &>/dev/null &
  done
  wait
  sleep 2

  # Wait for "Mid throughput is" to appear so the .res file is complete.
  for i in "${!IPS[@]}"; do
    local resfile="$variant_dir/${label}-${NAMES[$i]}.res"
    for _ in $(seq 1 30); do
      if [ -f "$resfile" ] && tail -c 102400 "$resfile" | grep -q "Mid throughput is"; then
        break
      fi
      sleep 1
    done
  done

  # Collect per-host CSV dumps. Each deptran_server writes
  #   results/recent_csv/<label>-<zooN>.csv
  # and results/recent_csv is on the shared NFS mount, so all 5 are visible
  # locally.
  cp "${ZOO_DIR}/results/recent_csv/${label}-"*.csv "$variant_dir/" 2>/dev/null || true

  # Snapshot the etcd server logs captured during this variant into the log dir.
  for i in "${!IPS[@]}"; do
    scp "ztang@${IPS[$i]}:/tmp/etcd-${NAMES[$i]}.log" "$variant_dir/etcd-${NAMES[$i]}.log" &>/dev/null || true
  done
}

# --------- main ---------

GIT_SHA_JANUS="$(cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_BRANCH_JANUS="$(cd "$REPO_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
GIT_SHA_ETCD="$(cd /home/users/ztang/etcd-jetpack 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
ETCD_VERSION="$(/home/users/ztang/.local/bin/etcd --version 2>&1 | head -1 | awk '{print $3}')"

# V1: raw etcd, no batch, no lease. mode=none_etcd.yml -m 0.
start_etcd_cluster "safe" "V1-raw"
run_deptran_variant "V1-raw" "none_etcd.yml" 0
stop_etcd_cluster

# V2: raw etcd, with batching (size=16, timeout=5 ms), no lease.
start_etcd_cluster "safe" "V2-batch"
run_deptran_variant "V2-batch" "none_etcd_batch.yml" 0
stop_etcd_cluster

# V3: raw etcd, with lease-based reads, no batching. Uses
# none_etcd_lease.yml (etcd_lease_reads: true) to mirror the server-side
# ETCD_READ_ONLY_OPTION=lease into the deptran latency model, so reads
# skip the simulated cross-host Raft round.
start_etcd_cluster "lease" "V3-lease"
run_deptran_variant "V3-lease" "none_etcd_lease.yml" 0
stop_etcd_cluster

# V4: Jetpack + etcd (merged-RPC variant). rule_etcd.yml (merge_leader_rpc: true).
# Uses stock etcd (no lease): ordering layer, so lease doesn't apply.
start_etcd_cluster "safe" "V4-jetpack-etcd"
run_deptran_variant "V4-jetpack-etcd" "rule_etcd.yml" 100
stop_etcd_cluster

# --------- settings.md + summary.md ---------

cat > "$RDIR/settings.md" <<SET
# Akkio etcd latency experiment — $(date -Iseconds)

Driver: \`scripts/run_akkio_exp.sh\`

## Cluster

- 5 zoo hosts (zoo1..zoo5 at 130.245.173.101..105).
- etcd replica set of 5 members; **leader intended on zoo1** (first in cluster
  list; etcd raft election typically picks the first eligible peer, but
  final leadership depends on raft-campaign timing — check per-variant etcd
  logs under \`log/etcd-*-zoo1.log\` for confirmation).
- Jetpack server thread pinned to core 17 via \`SERVER_CORE_ID\` (pthread
  \`pthread_setaffinity_np\` call; no process-wide \`taskset\`).
- WAN simulated delay: \`WAN_DELAY_MS=20\` (40 ms injected RTT).
- etcd binary: \`~/.local/bin/etcd\` (NFS-shared).

## Clients

- Total client sites: **100**, split **46 / 42 / 10 / 2 / 0** across
  zoo1..zoo5 (see \`config/${CLIENT_CFG_REL}\`).
- Per-site: open-loop, \`rate=1000\`, \`max_undone=20\`, \`n_concurrent=20\`
  (\`concurrent_20.yml\` + \`client_open_akkio.yml\`).
- Total outstanding in-flight requests ≈ 100 × 20 = **2000**.

## Workload

- \`config/rw_akkio.yml\`: uniform key distribution (\`dist: zipf\`,
  \`coefficient: 0\`), 1,000,000-key range, **50/50 read/write** mix.

## Variants

| Tag | Mode YAML | \`ETCD_READ_ONLY_OPTION\` | Notes |
|---|---|---|---|
| V1-raw | \`none_etcd.yml\` | \`safe\` (default: ReadIndex linearizable reads) | Baseline — raw etcd, no batching. |
| V2-batch | \`none_etcd_batch.yml\` (size=16, timeout=5 ms) | \`safe\` | Client-side Txn coalescing via etcd \`Txn\` API. Size OR time whichever first. |
| V3-lease | \`none_etcd_lease.yml\` (etcd_lease_reads: true) | \`lease\` (ReadOnlyLeaseBased) | Lease-based linearizable reads — skips ReadIndex round trip when leader lease valid. Requires the etcd patch in \`patches/etcd-lease-reads.patch\`. Paired with the deptran-side \`etcd_lease_reads: true\` knob so the simulated WAN round inside \`EtcdServer::Submit\` is skipped for reads (writes still pay the full cost). |
| V4-jetpack-etcd | \`rule_etcd.yml\` (merge_leader_rpc: true) | \`safe\` | Jetpack over etcd. Merge-RPC + pool opts always on (see \`docs/2026-04-22_jp-raft-fp100_merge-rpc-and-pool-opts_ab.md\`). Lease doesn't apply — etcd is used only as an ordering layer, so Range RPCs are not the hot path. |

## Versions

- janus: \`${GIT_SHA_JANUS}\` on branch \`${GIT_BRANCH_JANUS}\`.
- etcd source: \`/home/users/ztang/etcd-jetpack\` at \`${GIT_SHA_ETCD}\` — reports \`${ETCD_VERSION}\`.
- Lease-reads patch: \`patches/etcd-lease-reads.patch\` (applied into the
  working tree of etcd-jetpack; propagates via the NFS-shared
  \`~/.local/bin/etcd\`).

## Experiment details

- Each variant runs 30 s of workload. Per-host client latency is logged
  over the **middle 10 s** (the "Mid throughput is …" statistic uses the
  same window).
- Per-host p50/p90/p99 are parsed from \`log/<variant>/<label>-<zooN>.res\`
  (line "All-efficient-attempts statistics …").
- Cross-host aggregate p50/p90/p99 come from merging the leader-side
  latency CSVs in \`log/<variant>/\` — see \`scripts/merge_latency_csv.py\`.
- Cosmetic: etcd emits an "unrecognized environment variable
  ETCD_READ_ONLY_OPTION" warning at startup because the name shares the
  \`ETCD_*\` prefix etcd auto-maps to CLI flags. Harmless; the patched
  \`raftConfig\` still reads the env var as intended.

## Reproducibility

1. \`git checkout ${GIT_BRANCH_JANUS}\` at \`${GIT_SHA_JANUS}\` in the janus repo.
2. Ensure \`/home/users/ztang/etcd-jetpack\` is at \`${GIT_SHA_ETCD}\` with
   the contents of \`patches/etcd-lease-reads.patch\` applied to the
   working tree; then \`make build\` and \`cp bin/etcd ~/.local/bin/etcd\`.
3. \`bash scripts/gen_akkio_client_config.sh 46 42 10 2 0\` (idempotent).
4. \`bash scripts/run_akkio_exp.sh\` — outputs under \`results/<DATE>-akkio-etcd/\`.
SET

echo "[summary] running merge_latency_csv.py..."
python3 "$SCRIPT_DIR/merge_latency_csv.py" "$RDIR" > "$RDIR/summary.md" || true

echo "=== done. Artifacts at: $RDIR ==="
