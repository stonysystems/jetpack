#!/usr/bin/env bash
# results/2026-04-29-akkio/run.sh
#
# Reproducible runner for the 2026-04-29 Akkio AWS experiment.
# All experiments are launched via this script — see settings.md for spec.
#
# RULE: if anything goes wrong, fix this script and re-run; do NOT SSH
# into AWS instances and patch by hand. The script is the source of truth
# for the experiment.
#
# Subcommands (see usage() below): start | build | prep | gen-akkio |
#                                  run [Vs] | stop | all
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
TIMEOUT="${TIMEOUT:-180}"
# Per-DC per-site n_concurrent (rounded integers; see settings.md "Clients").
# z0=62 → 6×62=372 (~75%); z1=5 → 30 (vs 32); z2..z4=5 → 30 each (vs 31).
# Total 372 + 4×30 = 492 (~500). Tweak if you need exact 500 / different split.
Z0_CONC="${Z0_CONC:-62}"
Z1_CONC="${Z1_CONC:-5}"
Z2_CONC="${Z2_CONC:-5}"
Z3_CONC="${Z3_CONC:-5}"
Z4_CONC="${Z4_CONC:-5}"
SITES_PER_DC="${SITES_PER_DC:-6}"
AKKIO_YML_NAME="akkio_${SITES_PER_DC}_${SITES_PER_DC}_${SITES_PER_DC}_${SITES_PER_DC}_${SITES_PER_DC}c1s5r1p-aws.yml"

# -------- helpers --------
usage() {
    cat <<EOF
Usage: $0 <command> [args]

Commands:
  start              aws_start_instances.sh + 04-nfs.sh + wait for SSH on server0..4.
  build              Build deptran_server.{no_batch,batch} on SERVER_0 (NFS-shared).
  prep               Generate per-DC config yamls on SERVER_0:
                       - config/leader_locale_{0..4}.yml
                       - config/concurrent_z{0..4}.yml
                       - config/${AKKIO_YML_NAME}
  run [VARIANTS]     Run experiments. VARIANTS = comma-separated list from
                     V0,V1,V2,V3,V4,V5 (default: all). Examples:
                         $0 run                  # all
                         $0 run V1,V2,V3
                         $0 run V0
  stop               aws_stop_instances.sh.
  all                start + build + prep + run all + stop.

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
    declare -A ready
    while (( ${#ready[@]} < 5 )); do
        for i in 0 1 2 3 4; do
            local ip="${IPS[$i]}"
            [[ -n "${ready[$ip]:-}" ]] && continue
            if ssh -i "$KEY" -o ConnectTimeout=5 -o BatchMode=yes \
                   -o StrictHostKeyChecking=accept-new \
                   ubuntu@"$ip" true 2>/dev/null; then
                log "  server$i ($ip) READY"
                ready[$ip]=1
            fi
        done
        if (( ${#ready[@]} < 5 )); then
            (( SECONDS > deadline )) && { log "FATAL: SSH-ready timeout"; exit 1; }
            sleep 15
        fi
    done
    log "All 5 SSH-reachable. Re-mounting NFS..."
    bash "$SCRIPTS_DIR/04-nfs.sh"
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

    log "(c) Building deptran_server.{no_batch,batch} on server0..."
    # `-J` enables jemalloc (project-specific waf option, not -j parallelism;
    # waf already runs -j auto = nproc by default for compilation jobs).
    ssh0 bash <<'EOS'
set -e
cd /home/ubuntu/code/JetPack
echo "--- Build A: --disable-raft-batch -J (no_batch + jemalloc) ---"
python3 waf configure --disable-raft-batch -J build
cp build/deptran_server build/deptran_server.no_batch
echo "--- Build B: default + -J (batch + jemalloc) ---"
python3 waf configure -J build
cp build/deptran_server build/deptran_server.batch
ls -la build/deptran_server.{no_batch,batch}
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
    log "  cleanup JM signals on all 5 hosts..."
    local cleanup_pids=()
    for i in 0 1 2 3 4; do
        ssh -i "$KEY" -o BatchMode=yes ubuntu@"${IPS[$i]}" \
            "pkill -f '[s]cp_jm_file.sh' 2>/dev/null; rm -f /tmp/JM_Jetpack_* /home/ubuntu/code/tmp/JM_Jetpack_* /tmp/.jm_jetpack_seen 2>/dev/null; true" \
            >/dev/null 2>&1 &
        cleanup_pids+=($!)
    done
    for p in "${cleanup_pids[@]}"; do wait "$p" || true; done

    local pids=()
    for i in 0 1 2 3 4; do
        timeout "${TIMEOUT}s" ssh -i "$KEY" -o BatchMode=yes ubuntu@"${IPS[$i]}" "
cd /home/ubuntu/code/JetPack && ${bin} \
    -f config/${proto}.yml \
    -f config/leader_locale_${leader}.yml \
    -f config/client_open_z${i}.yml \
    -f config/${AKKIO_YML_NAME} \
    -f config/rw_akkio.yml \
    -f config/concurrent_z${i}.yml \
    -m ${MODE} -d ${DURATION} \
    -P server${i} -N ${label}-server${i}
" > "$LOG/${label}-server${i}.res" 2>&1 &
        pids+=($!)
    done
    local fail=0
    for p in "${pids[@]}"; do
        wait "$p" || { log "  ssh job $p exited $?"; fail=$((fail+1)); }
    done
    # Pull CSVs from NFS host (server0).
    scp -i "$KEY" -o BatchMode=yes \
        "ubuntu@${IPS[0]}:/home/ubuntu/code/JetPack/results/recent_csv/${label}-server*.csv" \
        "$LOG/" 2>/dev/null || true
    (( fail > 0 )) && log "  WARNING: $fail / 5 ssh jobs failed for $label"
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

    if want V0 "$req"; then
        for L in 0 1 2 3 4; do
            run_variant "V0-random-leader${L}" none_raft "$L" no_batch
        done
    fi
    want V1 "$req" && run_variant V1-raw                  none_raft       0 no_batch
    want V2 "$req" && run_variant V2-batch                none_raft       0 batch
    want V3 "$req" && run_variant V3-lease                none_raft_lease 0 no_batch
    want V4 "$req" && run_variant V4-jetpack-raft         rule_raft       0 no_batch
    want V5 "$req" && run_variant V5-jetpack-raft-batch   rule_raft       0 batch
    log "run done. $LOG/"
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
    stop)       cmd_stop ;;
    all)        cmd_start && cmd_build && cmd_prep && cmd_run all && cmd_stop ;;
    -h|--help|"") usage ;;
    *)          log "Unknown command: $cmd"; usage; exit 2 ;;
esac
