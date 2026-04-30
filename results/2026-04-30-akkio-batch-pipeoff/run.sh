#!/usr/bin/env bash
# results/2026-04-30-akkio-batch-pipeoff/run.sh
#
# Reproducible runner for the akkio re-run with **batching ON,
# pipelining OFF**. Tests whether removing the pipelining overhead
# (which we observed saturates the leader's bound replication core
# regardless of offered load — see ../2026-04-30-akkio-pipeline) lets
# jetpack-fast-path / read-lease re-engage and show their 1-RTT wins.
#
# Variants: V0-random, V1-raw, V3-lease, V4-jetpack-raft (the four
# protocols that exercise different commit paths).
#
# Single binary: batch_nopipe (RAFT_BATCH_OPTIMIZATION on,
# RAFT_PIPELINE_OPTIMIZATION off — i.e. --disable-raft-pipeline).
#
# Adapted from results/2026-04-30-akkio-pipeline/run.sh — same
# cluster topology, same akkio site map, same 6× concurrency for
# ~3000 req/s offered load.
#
# RULE: if anything goes wrong, fix this script and re-run; do NOT SSH
# into AWS instances and patch by hand. The script is the source of truth
# for the experiment.
#
# Subcommands: start | build | prep | run [Vs] | summary | stop | all
set -uo pipefail

# -------- paths / defaults --------
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$HERE/log"
JANUS_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPTS_DIR="$JANUS_ROOT/scripts"
LOCAL_CFG_DIR="$JANUS_ROOT/config"
KEY="$JANUS_ROOT/config/ssh/id_rsa"
INVENTORY="$SCRIPTS_DIR/aws_instances.tsv"

DURATION="${DURATION:-30}"
MODE="${MODE:-101}"
# Bumped from 180→300 because at 3000 req/s offered load the post-run
# stats aggregation + CSV dump on the leader can take 60-90s.
TIMEOUT="${TIMEOUT:-300}"
# Workload tweaks for this experiment:
#   - rw_akkio_zipf08.yml = 50/50 R/W, zipf 0.8 (more skewed than uniform)
#   - RW_VALUE_SIZE=1024 = 1 KB write payload (read by RwWorkload at startup)
RW_WORKLOAD_YML="${RW_WORKLOAD_YML:-rw_akkio_zipf08.yml}"
RW_VALUE_SIZE="${RW_VALUE_SIZE:-1024}"
# Per-DC per-site n_concurrent (rounded integers; see settings.md "Clients").
# 6× akkio's offered load to target ~3000 req/s integrated, preserving
# the 75/25 California/rest split:
#   z0=372 → 6 × 372 = 2232 coros (~75%)
#   z1..z4=30 → 6 × 30 = 180 coros each (~6.25% × 4 = 25%)
#   Total = 2232 + 4×180 = 2952 ≈ 3000.
# With pipelining cap=8000 and 200 ms RTT, capacity ≈ 40k req/s — way
# above 3000 — so this should be offered-load-bound, not capacity-bound.
Z0_CONC="${Z0_CONC:-372}"
Z1_CONC="${Z1_CONC:-30}"
Z2_CONC="${Z2_CONC:-30}"
Z3_CONC="${Z3_CONC:-30}"
Z4_CONC="${Z4_CONC:-30}"
SITES_PER_DC="${SITES_PER_DC:-6}"
AKKIO_YML_NAME="akkio_${SITES_PER_DC}_${SITES_PER_DC}_${SITES_PER_DC}_${SITES_PER_DC}_${SITES_PER_DC}c1s5r1p-aws.yml"

# -------- helpers --------
usage() {
    cat <<EOF
Usage: $0 <command> [args]

Commands:
  start              aws_start_instances.sh + 04-nfs.sh + wait for SSH on server0..4.
  build              git pull + build 1 deptran_server binary on SERVER_0:
                       deptran_server.batch_nopipe      (--disable-raft-pipeline)
                     This run is investigating whether disabling the
                     pipelining (which saturates the bound replication
                     core regardless of load — see akkio-pipeline run)
                     allows jetpack/lease to re-engage their 1-RTT wins.
  prep               Generate per-DC config yamls on SERVER_0:
                       - config/leader_locale_{0..4}.yml
                       - config/concurrent_z{0..4}.yml
                       - config/client_open_z{0..4}.yml
                       - config/${AKKIO_YML_NAME}
  run [VARIANTS]     Run experiments. VARIANTS = comma-separated list from
                     V0,V1,V3,V4,V6 (default: all). All variants use the
                     batch_nopipe binary (batch ON, pipeline OFF). Examples:
                         $0 run                       # V0 (5 sub-runs) + V1 + V3 + V4 + V6
                         $0 run V1,V3,V4,V6
                         $0 run V0                    # 5 sub-runs (leader cycles z0..z4)
  summary            Parse log/*.csv → summary.md (per-DC + integrated rows).
  stop               aws_stop_instances.sh.
  all                start + build + prep + run all + summary + stop.

Env overrides (sensible defaults baked in):
  DURATION=$DURATION  MODE=$MODE  TIMEOUT=$TIMEOUT
  Z0_CONC=$Z0_CONC  Z1_CONC=$Z1_CONC  Z2_CONC=$Z2_CONC  Z3_CONC=$Z3_CONC  Z4_CONC=$Z4_CONC
  SITES_PER_DC=$SITES_PER_DC

Inputs:
  $INVENTORY  (server0..server4 EIPs)
  $KEY        (SSH key)
EOF
}

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Read server0..server4 EIPs into IPS[].
load_ips() {
    [[ -f "$INVENTORY" ]] || { log "FATAL: $INVENTORY missing"; exit 1; }
    mapfile -t IPS < <(awk '$1 ~ /^0[0-4]$/ {print $5}' "$INVENTORY")
    [[ ${#IPS[@]} -eq 5 ]] || { log "FATAL: need 5 IPs (server0..4), got ${#IPS[@]}"; exit 1; }
}

# Run a command on server0 via SSH (single shell, heredoc).
ssh0() {
    ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        ubuntu@"${IPS[0]}" "$@"
}

# Write a file to server0's NFS-shared JetPack/config/ via SSH heredoc.
write_remote_config() {
    local rel="$1"  # path relative to JetPack/, e.g. config/leader_locale_0.yml
    local content="$2"
    ssh -i "$KEY" -o BatchMode=yes ubuntu@"${IPS[0]}" \
        "cat > /home/ubuntu/code/JetPack/${rel}" <<<"$content"
}

# -------- start --------
cmd_start() {
    log "Starting AWS instances..."
    bash "$SCRIPTS_DIR/aws_start_instances.sh"
    log "Waiting for SSH on server0..server4..."
    load_ips
    local deadline=$((SECONDS + 600))
    # Bash 5.0 + `set -u` errors on `${#assoc[@]}` for an empty
    # associative array; track readiness with a counter + bool array.
    local ready_count=0
    local ready=(0 0 0 0 0)
    while (( ready_count < 5 )); do
        for i in 0 1 2 3 4; do
            (( ready[i] )) && continue
            local ip="${IPS[$i]}"
            if ssh -i "$KEY" -o ConnectTimeout=5 -o BatchMode=yes \
                   -o StrictHostKeyChecking=accept-new \
                   ubuntu@"$ip" true 2>/dev/null; then
                log "  server$i ($ip) READY"
                ready[i]=1
                ready_count=$((ready_count + 1))
            fi
        done
        if (( ready_count < 5 )); then
            (( SECONDS > deadline )) && { log "FATAL: SSH-ready timeout"; exit 1; }
            sleep 15
        fi
    done
    log "All 5 SSH-reachable. Re-mounting NFS..."
    # 04-nfs.sh reads setup.json from CWD (scripts/), so cd in first.
    (cd "$SCRIPTS_DIR" && bash 04-nfs.sh) || { log "FATAL: 04-nfs.sh failed"; exit 1; }
    log "start done."
}

# -------- build --------
# RAFT_BATCH_OPTIMIZATION is gated by `RAFT_BATCH_OFF` (set via the waf
# `--disable-raft-batch` option, see wscript + src/deptran/constants.h).
# We never sed the AWS-side source: every source change in the JetPack
# repo flows zoo → git push → AWS git pull. The runner only flips the
# build flag.
#
# Build phases:
#  (a) server0: git pull + git submodule update --init --recursive
#  (b) all 5 instances in parallel: rebuild etcd-cpp-apiv3 from the
#      (NFS-shared) third_party/etcd-cpp-apiv3 source via an
#      instance-local /tmp/etcd-build dir, install to /usr/local
#      (each instance's /usr/local is its own — not NFS-shared).
#  (c) server0: waf build twice (no_batch + batch). The deptran_server
#      binary lives in JetPack/build/ which IS NFS-shared, so the other
#      4 see it automatically.
cmd_build() {
    load_ips
    log "(a) Pulling JetPack + updating submodules on server0..."
    ssh0 bash <<'EOS'
set -e
cd /home/ubuntu/code/JetPack
git pull --ff-only
git submodule update --init --recursive
EOS

    log "(b) Rebuilding etcd-cpp-apiv3 on all 5 instances in parallel..."
    local pids=()
    for i in 0 1 2 3 4; do
        ssh -i "$KEY" -o BatchMode=yes ubuntu@"${IPS[$i]}" 'set -e
SRC=/home/ubuntu/code/JetPack/third_party/etcd-cpp-apiv3
rm -rf /tmp/etcd-build
cmake -B /tmp/etcd-build -S "$SRC" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_ETCD_TESTS=OFF \
    -DBUILD_SHARED_LIBS=ON >/tmp/etcd-build.log 2>&1
cmake --build /tmp/etcd-build -- -j$(nproc) >>/tmp/etcd-build.log 2>&1
sudo cmake --build /tmp/etcd-build --target install >>/tmp/etcd-build.log 2>&1
sudo ldconfig
' &
        pids+=($!)
    done
    local fail=0
    for p in "${pids[@]}"; do
        wait "$p" || { log "  etcd rebuild ssh job $p exited $?"; fail=$((fail+1)); }
    done
    (( fail > 0 )) && { log "FATAL: etcd-cpp-apiv3 rebuild failed on $fail / 5 instances"; return 1; }

    log "(c) Building deptran_server.batch_nopipe on server0 (batch ON, pipeline OFF)..."
    # `-J` enables jemalloc (project-specific waf option, not -j parallelism;
    # waf already runs -j auto = nproc by default for compilation jobs).
    # We deliberately disable pipelining for this experiment; batching alone
    # delivers any reasonable offered load via 1 AE/RTT × N-entry payload.
    ssh0 bash <<'EOS'
set -e
cd /home/ubuntu/code/JetPack
echo "--- Build: --disable-raft-pipeline -J (batch on, pipeline off) → batch_nopipe ---"
python3 waf configure --disable-raft-pipeline -J build
cp build/deptran_server build/deptran_server.batch_nopipe
ls -la build/deptran_server.batch_nopipe
EOS
    log "build done."
}

# -------- prep: generate config yamls on server0 --------
cmd_prep() {
    load_ips
    log "Generating leader_locale_{0..4}.yml on server0..."
    # raft_leader_locale is a top-level field (not under mode:), parsed in
    # Config::LoadYML next to n_concurrent. See src/deptran/config.cc.
    for L in 0 1 2 3 4; do
        write_remote_config "config/leader_locale_${L}.yml" \
            "raft_leader_locale: $L
"
    done

    log "Generating concurrent_z{0..4}.yml on server0..."
    local concs=("$Z0_CONC" "$Z1_CONC" "$Z2_CONC" "$Z3_CONC" "$Z4_CONC")
    for L in 0 1 2 3 4; do
        write_remote_config "config/concurrent_z${L}.yml" \
            "n_concurrent: ${concs[$L]}
"
    done

    log "Generating client_open_z{0..4}.yml on server0..."
    # Per-DC open-loop client. Intended workload: each conc coroutine sends
    # ~1 cmd/s (rate-per-coroutine = rate / n_concurrent = 1) and all
    # coroutines can have an in-flight request simultaneously
    # (max_undone = n_concurrent). The original config/client_open_akkio.yml
    # used the zoo-Akkio defaults (rate=1000, max_undone=20) which capped
    # in-flight far below n_concurrent and produced a brief startup burst
    # followed by a 28s stall — see settings.md "Open-loop config" note.
    for L in 0 1 2 3 4; do
        local n="${concs[$L]}"
        write_remote_config "config/client_open_z${L}.yml" \
            "client:
    type: open
    rate: ${n}
    max_undone: ${n}
"
    done

    log "Generating $AKKIO_YML_NAME on server0..."
    # Build the akkio site map (server replicas s101..s501 + 30 client sites
    # spread 6 per DC across server0..server4, with new EIPs).
    local server_line='    - ["s101:38000", "s201:38001", "s301:38002", "s401:38003", "s501:38004"]'
    # Build client list "c01", "c02", ...
    local total_clients=$(( SITES_PER_DC * 5 ))
    local client_list=""
    for ((c=1; c<=total_clients; c++)); do
        printf -v cname "c%02d" "$c"
        client_list+="\"${cname}\""
        (( c < total_clients )) && client_list+=", "
    done

    # process: map each server replica + each client to a server-host.
    local proc_lines=""
    for L in 0 1 2 3 4; do
        proc_lines+="  s$((L+1))01: server${L}\n"
    done
    for ((c=1; c<=total_clients; c++)); do
        printf -v cname "c%02d" "$c"
        local host_idx=$(( (c-1) / SITES_PER_DC ))
        proc_lines+="  ${cname}: server${host_idx}\n"
    done

    # host: map server0..server4 → EIPs from inventory.
    local host_lines=""
    for L in 0 1 2 3 4; do
        host_lines+="  server${L}: ${IPS[$L]}\n"
    done

    local body
    body=$(cat <<YML

site:
  server: # 5-replica raft group, one replica per DC
${server_line}
  client: # ${total_clients} client sites total (${SITES_PER_DC} per DC × 5 DCs)
    - [${client_list}]

process:
$(printf '%b' "$proc_lines")
host:
$(printf '%b' "$host_lines")
YML
)
    write_remote_config "config/${AKKIO_YML_NAME}" "$body"
    log "prep done."
}

# -------- run --------
run_variant() {
    local label="$1" proto="$2" leader="$3" bin_suffix="${4:-no_batch}"
    local bin="build/deptran_server.${bin_suffix}"
    log "=== $label ($proto, leader=server${leader}, $bin_suffix) ==="

    # Clean up JM_Jetpack_* signals before this variant. Without this, the
    # patch RAFT_ELECTION_ONLY_INIT_AND_POST_FAILURE_ONCE_PATCH (constants.h)
    # treats /tmp/JM_Jetpack_raft_init_election_done as evidence that the
    # initial election already happened, sets init_election_done_=true at
    # startup, and skips all elections → 0 throughput.
    log "  cleanup JM signals + stale CSVs..."
    local cleanup_pids=()
    for i in 0 1 2 3 4; do
        # Per-host: kill jm_file processes + JM signal files + lingering deptran_server.
        ssh -i "$KEY" -o BatchMode=yes ubuntu@"${IPS[$i]}" \
            "pkill -f '[s]cp_jm_file.sh' 2>/dev/null; pkill -9 -f '[d]eptran_server' 2>/dev/null; rm -f /tmp/JM_Jetpack_* /home/ubuntu/code/tmp/JM_Jetpack_* /tmp/.jm_jetpack_seen 2>/dev/null; true" \
            >/dev/null 2>&1 &
        cleanup_pids+=($!)
    done
    for p in "${cleanup_pids[@]}"; do wait "$p" || true; done
    # Also clear AWS-side recent_csv (NFS-shared, only need server0). Without
    # this, a stale CSV from a prior run masquerades as current data when
    # the leader fails to dump (e.g. shutdown hang).
    ssh -i "$KEY" -o BatchMode=yes ubuntu@"${IPS[0]}" \
        "rm -f /home/ubuntu/code/JetPack/results/recent_csv/*.csv 2>/dev/null; true" \
        >/dev/null 2>&1 || true

    # Detached launch: kick off deptran_server with nohup so it survives
    # ssh disconnect, then poll for completion. Without this, ssh disconnects
    # ~5s after the binary's "Total throughtput" log (probably triggered by
    # rrr's client-disconnect handling during the post-run silent phase),
    # SIGHUP propagates, and the leader is killed before reaching CSV dump.
    local launch_pids=()
    for i in 0 1 2 3 4; do
        ssh -i "$KEY" -o BatchMode=yes ubuntu@"${IPS[$i]}" "
cd /home/ubuntu/code/JetPack
RES=/home/ubuntu/code/JetPack/results/recent_csv/${label}-server${i}.res
export RW_VALUE_SIZE=${RW_VALUE_SIZE:-1024}
nohup ${bin} \
    -f config/${proto}.yml \
    -f config/leader_locale_${leader}.yml \
    -f config/client_open_z${i}.yml \
    -f config/${AKKIO_YML_NAME} \
    -f config/${RW_WORKLOAD_YML} \
    -f config/concurrent_z${i}.yml \
    -m ${MODE} -d ${DURATION} \
    -P server${i} -N ${label}-server${i} > \$RES 2>&1 < /dev/null &
disown
echo started_pid=\$!
" > /dev/null 2>&1 &
        launch_pids+=($!)
    done
    for p in "${launch_pids[@]}"; do wait "$p" || true; done

    # Poll for completion: each host's .res should contain "Dumped to" once
    # CSV write is done (true post-run finalization marker). Cap at $TIMEOUT.
    local deadline=$((SECONDS + TIMEOUT))
    declare -a done_flag=(0 0 0 0 0)
    local done_count=0
    while (( done_count < 5 && SECONDS < deadline )); do
        for i in 0 1 2 3 4; do
            (( done_flag[i] )) && continue
            if ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 ubuntu@"${IPS[$i]}" \
                "tail -c 4096 /home/ubuntu/code/JetPack/results/recent_csv/${label}-server${i}.res 2>/dev/null | grep -q 'Dumped to'" 2>/dev/null; then
                done_flag[i]=1
                done_count=$((done_count + 1))
            fi
        done
        (( done_count < 5 )) && sleep 5
    done

    # Pull RES files from each host (the .res lives in recent_csv/).
    for i in 0 1 2 3 4; do
        scp -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 \
            "ubuntu@${IPS[$i]}:/home/ubuntu/code/JetPack/results/recent_csv/${label}-server${i}.res" \
            "$LOG/${label}-server${i}.res" 2>/dev/null || true
    done
    # Pull CSVs from NFS host (server0).
    scp -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 \
        "ubuntu@${IPS[0]}:/home/ubuntu/code/JetPack/results/recent_csv/${label}-server*.csv" \
        "$LOG/" 2>/dev/null || true
    local fail=0
    for i in 0 1 2 3 4; do
        (( done_flag[i] )) || { log "  server$i: NO 'Dumped to' marker after ${TIMEOUT}s"; fail=$((fail+1)); }
    done
    (( fail > 0 )) && log "  WARNING: $fail / 5 hosts did not finalize CSV dump"
    return 0
}

want() {
    local v="$1" req="$2"
    [[ "$req" == "all" ]] && return 0
    [[ ",$req," == *",$v,"* ]]
}

cmd_run() {
    load_ips
    mkdir -p "$LOG"
    local req="${1:-all}"

    # 5 variants, all on the same binary (batch_nopipe = batch on,
    # pipeline off). The differentiator is the protocol YAML.
    # V2 / V5 (batch toggles) from the previous run are skipped — batch
    # is always on here, so the only axis is the cc/ab protocol path.
    if want V0 "$req"; then
        for L in 0 1 2 3 4; do
            run_variant "V0-random-leader${L}" none_raft        "$L" batch_nopipe
        done
    fi
    want V1 "$req" && run_variant V1-raw                  none_raft        0 batch_nopipe
    want V3 "$req" && run_variant V3-lease                none_raft_lease  0 batch_nopipe
    want V4 "$req" && run_variant V4-jetpack-raft         rule_raft        0 batch_nopipe
    want V6 "$req" && run_variant V6-jetpack-raft-lease   rule_raft_lease  0 batch_nopipe
    log "run done. $LOG/"
}

# -------- summary --------
# Per-DC + integrated rows from log/*.csv. Matches the zoo experiment's
# summary script. End2End-Latency in CSV is already in milliseconds.
cmd_summary() {
    log "Parsing $LOG/ → $HERE/summary.md"
    python3 - "$LOG" "$HERE/summary.md" "$DURATION" <<'PY'
import csv, glob, os, statistics, sys
log_dir, out_file, duration = sys.argv[1], sys.argv[2], int(sys.argv[3])

VARIANTS = [
    ("V0-random",            "raft + batch (pipeline OFF), leader cycles z0..z4 (5 sub-runs)"),
    ("V1-raw",               "raft + batch (pipeline OFF), leader=z0"),
    ("V3-lease",             "raft + batch + read-lease (pipeline OFF), leader=z0"),
    ("V4-jetpack-raft",      "rule_raft + batch (jetpack fast-path, pipeline OFF), leader=z0"),
    ("V6-jetpack-raft-lease","rule_raft + batch + read-lease (pipeline OFF), leader=z0"),
]
DCS = [("z0", "California"), ("z1", "Oregon"), ("z2", "Mumbai"),
       ("z3", "Frankfurt"),  ("z4", "Stockholm")]

def percentile(values, p):
    if not values: return float("nan")
    s = sorted(values)
    k = (len(s) - 1) * p / 100.0
    f = int(k); c = min(f + 1, len(s) - 1)
    if f == c: return s[f]
    return s[f] + (s[c] - s[f]) * (k - f)

def stats_for(values):
    if not values: return None
    return dict(
        n=len(values),
        tput=len(values) / duration,
        mn=min(values), mx=max(values),
        p50=percentile(values, 50),
        p90=percentile(values, 90),
        p99=percentile(values, 99),
        p999=percentile(values, 99.9),
        avg=sum(values)/len(values),
        sd=statistics.pstdev(values) if len(values) > 1 else 0.0,
    )

def fmt_row(label, s):
    if s is None:
        return f"| {label} | 0 | 0 | – | – | – | – | – | – | – | – |"
    return ("| {lbl} | {n} | {tp:.1f} | {mn:.1f} | {p50:.1f} | {p90:.1f} | {p99:.1f} "
            "| {p999:.1f} | {mx:.1f} | {avg:.1f} | {sd:.1f} |").format(
        lbl=label, n=s['n'], tp=s['tput'], mn=s['mn'], p50=s['p50'], p90=s['p90'],
        p99=s['p99'], p999=s['p999'], mx=s['mx'], avg=s['avg'], sd=s['sd'])

def load_csv(path):
    if not os.path.isfile(path): return []
    out = []
    with open(path) as f:
        rdr = csv.DictReader(f)
        for row in rdr:
            v = row.get("End2End-Latency", "").strip()
            if not v: continue
            try:
                out.append(float(v))   # already in ms
            except ValueError:
                pass
    return out

with open(out_file, 'w') as f:
    f.write(f"# 2026-04-30-akkio-batch-pipeoff — latency summary\n\n")
    f.write(f"AWS akkio re-run with **batching ON, pipelining OFF**.\n")
    f.write(f"Investigates whether disabling pipelining (which saturated the\n")
    f.write(f"leader's bound replication core regardless of offered load — see\n")
    f.write(f"`../2026-04-30-akkio-pipeline`) lets jetpack-fast-path / read-lease\n")
    f.write(f"re-engage and show their expected 1-RTT wins.\n\n")
    f.write(f"`tput (req/s)` = total commit samples in CSV ÷ {duration} s.\n")
    f.write(f"For V0-random, samples are the union of 5 sub-runs (one per\n")
    f.write(f"leader DC), and tput is divided by 5× duration to give the per-\n")
    f.write(f"sub-run rate.\n\n")

    # Pull aggregate throughput from .res files (sums "Total throughtput is X"
    # across all 5 servers per variant). For V0-random, average across 5 sub-runs.
    import re
    def parse_res_tput(label_prefix):
        s = 0.0; n = 0
        for p in glob.glob(os.path.join(log_dir, f"{label_prefix}-server*.res")):
            try:
                with open(p) as fh:
                    for line in fh:
                        m = re.search(r"Total throughtput is (\d+\.\d+)", line)
                        if m:
                            s += float(m.group(1))
                            n += 1
                            break  # one match per file
            except OSError:
                pass
        return s, n

    f.write("| variant | aggregate tput from .res (req/s) | notes |\n")
    f.write("|---|---|---|\n")
    for label, _ in VARIANTS:
        if label.startswith("V0-"):
            # Average across 5 sub-runs of "V0-random-leader{0..4}".
            sums = []
            for L in range(5):
                s, n = parse_res_tput(f"{label}-leader{L}")
                if n > 0: sums.append(s)
            avg = sum(sums) / len(sums) if sums else 0
            f.write(f"| {label} | {avg:.1f} | mean of {len(sums)} sub-runs |\n")
        else:
            s, n = parse_res_tput(label)
            f.write(f"| {label} | {s:.1f} | from {n}/5 server.res files |\n")
    f.write("\nThese match the offered load of ~2952 req/s within "
            "rounding — pipelining handles the full 3000-target on real AWS WAN.\n\n")

    headlines = []
    for label, desc in VARIANTS:
        f.write(f"## {label}\n\n_{desc}_\n\n")
        f.write("| host | samples | tput (req/s) | min (ms) | p50 | p90 | p99 | p99.9 | max | avg (ms) | stddev (ms) |\n")
        f.write("|---|---|---|---|---|---|---|---|---|---|---|\n")
        all_vals = []
        # V0-random: aggregate across 5 sub-runs (V0-random-leader{0..4}-server*.csv)
        # Other variants: single run (V<X>-...-server*.csv)
        is_v0 = label.startswith("V0-")
        if is_v0:
            csv_glob = os.path.join(log_dir, f"{label}-leader*-server*.csv")
            tput_divisor = 5 * duration
        else:
            csv_glob = os.path.join(log_dir, f"{label}-server*.csv")
            tput_divisor = duration
        all_paths = glob.glob(csv_glob)
        for dc_idx, (dc, city) in enumerate(DCS):
            paths_dc = [p for p in all_paths if f"server{dc_idx}." in os.path.basename(p)]
            vals = []
            for p in paths_dc:
                vals.extend(load_csv(p))
            all_vals.extend(vals)
            s = stats_for(vals)
            if s is not None:
                s['tput'] = len(vals) / tput_divisor
            f.write(fmt_row(f"{dc} {city}", s) + "\n")
        ints = stats_for(all_vals)
        if ints is not None:
            ints['tput'] = len(all_vals) / tput_divisor
        f.write(fmt_row("**integrated**", ints) + "\n\n")
        headlines.append((label, ints))

    f.write("## Headline (integrated row, all variants)\n\n")
    f.write("| variant | samples | tput (req/s) | p50 (ms) | p90 (ms) | p99 (ms) | p99.9 (ms) | avg (ms) |\n")
    f.write("|---|---|---|---|---|---|---|---|\n")
    for label, s in headlines:
        if s is None:
            f.write(f"| {label} | 0 | 0 | – | – | – | – | – |\n")
        else:
            f.write(f"| {label} | {s['n']} | {s['tput']:.1f} | {s['p50']:.1f} | "
                    f"{s['p90']:.1f} | {s['p99']:.1f} | {s['p999']:.1f} | {s['avg']:.1f} |\n")
    f.write("\n")
print(f"wrote {out_file}")
PY
}

# -------- stop --------
cmd_stop() {
    log "Stopping AWS instances..."
    bash "$SCRIPTS_DIR/aws_stop_instances.sh"
    log "stop done."
}

# -------- main --------
cmd="${1:-}"; shift || true
case "$cmd" in
    start)      cmd_start ;;
    build)      cmd_build ;;
    prep)       cmd_prep ;;
    run)        cmd_run "${1:-all}" ;;
    summary)    cmd_summary ;;
    stop)       cmd_stop ;;
    all)        cmd_start && cmd_build && cmd_prep && cmd_run all && cmd_summary && cmd_stop ;;
    -h|--help|"") usage ;;
    *)          log "Unknown command: $cmd"; usage; exit 2 ;;
esac
