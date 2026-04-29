#!/usr/bin/env bash
# results/2026-04-30-raft-pipeline-zoo/run.sh
#
# Reproducible runner for the local-zoo raft-pipelining experiment.
# See settings.md for the full spec. All experiments are launched
# via this script — fix this script and re-run if anything breaks.
#
# Subcommands: build | prep | run [variants] | summary | all
set -uo pipefail

# -------- paths / defaults --------
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$HERE/log"
JANUS_ROOT="$(cd "$HERE/../.." && pwd)"
CFG_DIR="$JANUS_ROOT/config"
ZOO_USER="${ZOO_USER:-ztang}"

DURATION="${DURATION:-30}"
MODE="${MODE:-0}"             # cc=none, ab=raft (configured via none_raft.yml)
TIMEOUT="${TIMEOUT:-180}"
WAN_DELAY_MS="${WAN_DELAY_MS:-100}"      # one-way; 100 ms → 200 ms RTT
N_CONCURRENT="${N_CONCURRENT:-500}"      # client coros on c01 (zoo-001)
SERVER_CORE_ID="${SERVER_CORE_ID:-1}"

# 4 zoo hosts (avoiding zoo-005 per user request); zoo-002 hosts s201+s501.
ZOO_IPS=(130.245.173.101 130.245.173.102 130.245.173.103 130.245.173.104)
ZOO_NAMES=(zoo1 zoo2 zoo3 zoo4)
SITE_YML_NAME="raft_pipeline_5r1c-zoo.yml"
LIB_PATH_EXPORT='export LD_LIBRARY_PATH=/home/users/ztang/local/lib:$LD_LIBRARY_PATH'

usage() {
    cat <<EOF
Usage: $0 <command> [args]

Commands:
  build                Build all 4 deptran_server variants on this host:
                         build/deptran_server.batch_pipe         (default)
                         build/deptran_server.batch_nopipe       (--disable-raft-pipeline)
                         build/deptran_server.nobatch_pipe       (--disable-raft-batch)
                         build/deptran_server.nobatch_nopipe     (--disable-raft-batch --disable-raft-pipeline)
                       Skipped if all 4 binaries already exist.
  prep                 Write per-experiment YAML configs into $CFG_DIR:
                         leader_locale_0.yml, concurrent_${N_CONCURRENT}_pipe.yml,
                         client_open_pipe.yml, $SITE_YML_NAME
  run [VARIANTS]       Run experiments. VARIANTS = comma list from
                       V1raw,V1pipe,V2batch,V2pipe (default: all)
  summary              Parse log/ → log/summary.md
  all                  build → prep → run → summary

Env overrides:
  DURATION=$DURATION  MODE=$MODE  TIMEOUT=$TIMEOUT
  WAN_DELAY_MS=$WAN_DELAY_MS  N_CONCURRENT=$N_CONCURRENT
  SERVER_CORE_ID=$SERVER_CORE_ID  ZOO_USER=$ZOO_USER

Cluster:
  zoo-001 (\${ZOO_IPS[0]}): s101 (leader) + c01
  zoo-002 (\${ZOO_IPS[1]}): s201 + s501
  zoo-003 (\${ZOO_IPS[2]}): s301
  zoo-004 (\${ZOO_IPS[3]}): s401
EOF
}

log() { echo "[$(date +%H:%M:%S)] $*"; }

# -------- build --------
cmd_build() {
    cd "$JANUS_ROOT"
    local need_build=0
    for f in build/deptran_server.batch_pipe build/deptran_server.batch_nopipe \
             build/deptran_server.nobatch_pipe build/deptran_server.nobatch_nopipe; do
        [[ -x $f ]] || need_build=1
    done
    if (( need_build == 0 )); then
        log "All 4 binaries present, skipping build."
        ls -la build/deptran_server.{batch,nobatch}_{pipe,nopipe}
        return 0
    fi

    log "(1/4) Building default (batch ON, pipeline ON)..."
    python3 waf configure                                       >/tmp/raftpipe-build.log 2>&1 || { log "configure failed; see /tmp/raftpipe-build.log"; return 1; }
    python3 waf build                                          >>/tmp/raftpipe-build.log 2>&1 || { log "build failed"; return 1; }
    cp build/deptran_server build/deptran_server.batch_pipe

    log "(2/4) Building --disable-raft-pipeline (batch ON, pipeline OFF)..."
    python3 waf configure --disable-raft-pipeline              >>/tmp/raftpipe-build.log 2>&1
    python3 waf build                                          >>/tmp/raftpipe-build.log 2>&1
    cp build/deptran_server build/deptran_server.batch_nopipe

    log "(3/4) Building --disable-raft-batch (batch OFF, pipeline ON)..."
    python3 waf configure --disable-raft-batch                 >>/tmp/raftpipe-build.log 2>&1
    python3 waf build                                          >>/tmp/raftpipe-build.log 2>&1
    cp build/deptran_server build/deptran_server.nobatch_pipe

    log "(4/4) Building --disable-raft-batch --disable-raft-pipeline (legacy)..."
    python3 waf configure --disable-raft-batch --disable-raft-pipeline >>/tmp/raftpipe-build.log 2>&1
    python3 waf build                                          >>/tmp/raftpipe-build.log 2>&1
    cp build/deptran_server build/deptran_server.nobatch_nopipe

    ls -la build/deptran_server.{batch,nobatch}_{pipe,nopipe}
    log "build done."
}

# -------- prep: write YAMLs --------
cmd_prep() {
    log "Writing $CFG_DIR/leader_locale_0.yml..."
    cat > "$CFG_DIR/leader_locale_0.yml" <<EOF
raft_leader_locale: 0
EOF

    log "Writing $CFG_DIR/concurrent_${N_CONCURRENT}_pipe.yml..."
    cat > "$CFG_DIR/concurrent_${N_CONCURRENT}_pipe.yml" <<EOF
n_concurrent: ${N_CONCURRENT}
EOF

    log "Writing $CFG_DIR/client_open_pipe.yml..."
    # Open-loop client matching the akkio fix:
    #   each conc coro sends ~1 req/s (rate / n_concurrent = 1)
    #   all coros may have 1 in-flight at once (max_undone = n_concurrent)
    cat > "$CFG_DIR/client_open_pipe.yml" <<EOF
client:
    type: open
    rate: ${N_CONCURRENT}
    max_undone: ${N_CONCURRENT}
EOF

    log "Writing $CFG_DIR/$SITE_YML_NAME..."
    cat > "$CFG_DIR/$SITE_YML_NAME" <<EOF

site:
  server: # 5-replica raft group
    - ["s101:38000", "s201:38001", "s301:38002", "s401:38003", "s501:38004"]
  client: # single client process
    - ["c01"]

process:
  s101: ${ZOO_NAMES[0]}
  s201: ${ZOO_NAMES[1]}
  s301: ${ZOO_NAMES[2]}
  s401: ${ZOO_NAMES[3]}
  s501: ${ZOO_NAMES[1]}    # colocated with s201 on zoo-002 (avoiding zoo-005)
  c01:  ${ZOO_NAMES[0]}    # client on leader host

host:
  ${ZOO_NAMES[0]}: ${ZOO_IPS[0]}
  ${ZOO_NAMES[1]}: ${ZOO_IPS[1]}
  ${ZOO_NAMES[2]}: ${ZOO_IPS[2]}
  ${ZOO_NAMES[3]}: ${ZOO_IPS[3]}
EOF

    log "prep done. Configs: leader_locale_0.yml, concurrent_${N_CONCURRENT}_pipe.yml, client_open_pipe.yml, $SITE_YML_NAME"
}

# -------- run --------
# Cleanup leftover deptran_server processes + JM signal files on all 4 hosts.
cleanup_hosts() {
    local pids=()
    for ip in "${ZOO_IPS[@]}"; do
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$ZOO_USER@$ip" \
            "pkill -9 deptran_server 2>/dev/null; rm -f /tmp/JM_* /tmp/.jm_jetpack_seen 2>/dev/null; true" &
        pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || true; done
    sleep 4   # let TIME_WAIT clear on bind ports
}

# Clean recent_csv on the NFS-shared build dir (one location since /home is shared).
clean_recent_csv() {
    rm -f "$JANUS_ROOT/results/recent_csv/"*.csv 2>/dev/null || true
    mkdir -p "$JANUS_ROOT/results/recent_csv"
}

# run_variant <label> <binary_suffix>
run_variant() {
    local label="$1" bin_suffix="$2"
    local bin="$JANUS_ROOT/build/deptran_server.${bin_suffix}"
    [[ -x $bin ]] || { log "FATAL: missing $bin"; return 1; }

    log "=== $label ($bin_suffix) ==="
    cleanup_hosts
    clean_recent_csv

    # Common args. -P picks the host name → all sites mapped to that host run in this process.
    local common_args="\
        -f config/none_raft.yml \
        -f config/leader_locale_0.yml \
        -f config/client_open_pipe.yml \
        -f config/${SITE_YML_NAME} \
        -f config/rw_1000000.yml \
        -f config/concurrent_${N_CONCURRENT}_pipe.yml \
        -m ${MODE} -d ${DURATION}"

    local pids=()
    for i in 0 1 2 3; do
        local ip="${ZOO_IPS[$i]}"
        local name="${ZOO_NAMES[$i]}"
        local resfile="$LOG/${label}-${name}.res"
        local run_name="${label}-${name}"
        timeout "${TIMEOUT}s" ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$ZOO_USER@$ip" "
${LIB_PATH_EXPORT}
export WAN_DELAY_MS=${WAN_DELAY_MS}
export SERVER_CORE_ID=${SERVER_CORE_ID}
cd $JANUS_ROOT && $bin ${common_args} -P ${name} -N ${run_name}
" > "$resfile" 2>&1 &
        pids+=($!)
    done
    local fail=0
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}"; then
            local s=$?
            if (( s == 124 )); then
                log "  ${ZOO_NAMES[$i]}: TIMED OUT"
            else
                log "  ${ZOO_NAMES[$i]}: exit $s"
            fi
            fail=$((fail+1))
        fi
    done

    # Wait for "Mid throughput is" line (the final stats marker).
    for i in 0 1 2 3; do
        local resfile="$LOG/${label}-${ZOO_NAMES[$i]}.res"
        for _ in $(seq 1 30); do
            [[ -f $resfile ]] && tail -c 102400 "$resfile" 2>/dev/null | grep -q "Mid throughput is" && break
            sleep 1
        done
    done

    # Pull CSVs (NFS-shared, but copy to log/ for self-containment).
    cp "$JANUS_ROOT/results/recent_csv/${label}-"*.csv "$LOG/" 2>/dev/null || true

    # Compact summary line.
    local total=0
    for i in 0 1 2 3; do
        local resfile="$LOG/${label}-${ZOO_NAMES[$i]}.res"
        if [[ -f $resfile ]]; then
            local tp
            tp=$(tail -c 102400 "$resfile" | grep -m1 "Mid throughput is" | awk '{print $NF}')
            tp=${tp:-0}
            total=$(awk -v a="$total" -v b="$tp" 'BEGIN{printf "%.2f", a+b}')
            printf "  %-8s  Mid-tput=%s\n" "${ZOO_NAMES[$i]}" "$tp"
        else
            printf "  %-8s  NO RES\n" "${ZOO_NAMES[$i]}"
        fi
    done
    log "  total Mid-tput across 5 replicas: $total req/s"
    (( fail > 0 )) && log "  WARNING: $fail / 4 ssh jobs reported non-zero exit"
    return 0
}

want() {
    local v="$1" req="$2"
    [[ "$req" == "all" ]] && return 0
    [[ ",$req," == *",$v,"* ]]
}

cmd_run() {
    mkdir -p "$LOG"
    local req="${1:-all}"
    want V1raw     "$req" && run_variant V1-raw                nobatch_nopipe
    want V1pipe    "$req" && run_variant V1-pipeline           nobatch_pipe
    want V2batch   "$req" && run_variant V2-batch              batch_nopipe
    want V2pipe    "$req" && run_variant V2-batch+pipeline     batch_pipe
    log "run done. log/ has .res + .csv files."
}

# -------- summary --------
cmd_summary() {
    log "Parsing $LOG/ → $HERE/summary.md"
    python3 - "$LOG" "$HERE/summary.md" "$DURATION" <<'PY'
import csv, glob, os, statistics, sys
log_dir, out_file, duration = sys.argv[1], sys.argv[2], int(sys.argv[3])

VARIANTS = [
    ("V1-raw",                "no batch, no pipeline (legacy serial loop)"),
    ("V1-pipeline",           "no batch, pipelined (cap=64 in-flight per follower)"),
    ("V2-batch",              "batch + no pipeline"),
    ("V2-batch+pipeline",     "batch + pipelined (cap=64 in-flight per follower)"),
]
HOSTS = ["zoo1", "zoo2", "zoo3", "zoo4"]

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
    """Return list of End2End-Latency floats (ms)."""
    if not os.path.isfile(path): return []
    out = []
    with open(path) as f:
        rdr = csv.DictReader(f)
        for row in rdr:
            v = row.get("End2End-Latency", "").strip()
            if not v: continue
            try:
                # End2End-Latency is already in milliseconds
                # (SimpleRWCommand::GetCurrentMsTime returns ms).
                out.append(float(v))
            except ValueError:
                pass
    return out

with open(out_file, 'w') as f:
    f.write(f"# 2026-04-30-raft-pipeline-zoo — latency summary\n\n")
    f.write(f"Generated from `log/*.csv` (End2End-Latency column, milliseconds).\n\n")
    f.write(f"`tput (req/s)` = total commit samples in CSV ÷ {duration} s nominal duration.\n\n")
    f.write(f"5 replicas on zoo-001..004 (s501 colocated with s201 on zoo-002),\n")
    f.write(f"WAN_DELAY_MS=100 → ~100 ms simulated RTT (WAN_WAIT applied only on\n")
    f.write(f"leader's send path; reply uses real loopback), n_concurrent=500.\n\n")
    f.write(f"Only zoo1 hosts the client (c01); follower hosts (zoo2-zoo4)\n")
    f.write(f"have empty CSVs by design — they're shown as 0-sample rows for completeness.\n\n")

    headlines = []
    for label, desc in VARIANTS:
        f.write(f"## {label}\n\n")
        f.write(f"_{desc}_\n\n")
        f.write("| host | samples | tput (req/s) | min (ms) | p50 | p90 | p99 | p99.9 | max | avg (ms) | stddev (ms) |\n")
        f.write("|---|---|---|---|---|---|---|---|---|---|---|\n")
        all_vals = []
        for h in HOSTS:
            paths = glob.glob(os.path.join(log_dir, f"{label}-{h}-*.csv")) + \
                    glob.glob(os.path.join(log_dir, f"{label}-{h}.csv"))
            vals = []
            for p in paths:
                vals.extend(load_csv(p))
            all_vals.extend(vals)
            f.write(fmt_row(h, stats_for(vals)) + "\n")
        ints = stats_for(all_vals)
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

# -------- main --------
cmd="${1:-}"; shift || true
case "$cmd" in
    build)      cmd_build ;;
    prep)       cmd_prep ;;
    run)        cmd_run "${1:-all}" ;;
    summary)    cmd_summary ;;
    all)        cmd_build && cmd_prep && cmd_run all && cmd_summary ;;
    -h|--help|"") usage ;;
    *)          log "Unknown command: $cmd"; usage; exit 2 ;;
esac
