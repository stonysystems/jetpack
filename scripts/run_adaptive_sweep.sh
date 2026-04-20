#!/bin/bash
# run_adaptive_sweep.sh — adaptive client-count sweep to find the saturation
# point for a single protocol.
#
# Protocol flow:
#   1. Measure p50 at N=1 to establish the baseline.
#   2. stop_p50 := 2 * baseline (saturation criterion, per experiment spec).
#   3. Probe N=50 and N=100. If either trips stop_p50, bisect between the
#      last unsaturated N and the first saturated N until |hi-lo| <= TOL.
#      Otherwise extend upward (150, 200, 300, 500) until a stop fires.
#   4. Produces <result_dir>/<label>-adaptive.csv and a pretty-printed
#      per-protocol table (tput + zoo2/zoo3 p50/p90/p99 + per-host CPU avg).
#
# Usage:
#   SERVER_CORE_ID=17 ./run_adaptive_sweep.sh <label> <cfg.yml> <mode> <result_dir>
# Example:
#   SERVER_CORE_ID=17 ./run_adaptive_sweep.sh naive_raft none_naive_raft.yml 0 results/2026-04-20-naive-raft

set -uo pipefail

LABEL="$1"
CFG="$2"
MODE="$3"
RDIR="$4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
mkdir -p "$RDIR"

BISECT_TOL=5     # stop bisecting once |hi - lo| <= 5 clients
UP_SEQ=(150 200 300 500)  # extension points if N=100 doesn't saturate

export SERVER_CORE_ID="${SERVER_CORE_ID:-1}"

OUT_CSV="$RDIR/${LABEL}-adaptive.csv"
echo "N,tput,zoo2_p50,zoo2_p90,zoo2_p99,zoo3_p50,zoo3_p90,zoo3_p99,zoo1_cpu,zoo2_cpu,zoo3_cpu,zoo4_cpu,zoo5_cpu,avg_cpu,stopped" > "$OUT_CSV"

run_point() {
  local N="$1"
  if [ "$N" -eq 1 ]; then
    # Baseline: place the single client on zoo2 (the fixed leader for
    # leader-routing protocols). Otherwise "zoo2 p50" is empty and the
    # stop criterion (2x baseline) degenerates. Named -zoo2 so we don't
    # stomp the generic 1c1s5r5p-zoo.yml that callers of gen_client_config
    # would produce for other uses.
    local CLI_CFG="1c1s5r5p-zoo2.yml"
    local OUT="$REPO_DIR/config/$CLI_CFG"
    if [ ! -f "$OUT" ]; then
      cat > "$OUT" <<'EOF'

site:
  server: # each line is a partition, the first is the master site_name:port
    - ["s101:38000", "s201:38001", "s301:38002", "s401:38003", "s501:38004"]
  client: # each line is a partition
    - ["c01"]


process:
  s101: zoo1
  s201: zoo2
  s301: zoo3
  s401: zoo4
  s501: zoo5
  c01: zoo2

host:
  zoo1: 130.245.173.101
  zoo2: 130.245.173.102
  zoo3: 130.245.173.103
  zoo4: 130.245.173.104
  zoo5: 130.245.173.105
EOF
    fi
  else
    bash "$SCRIPT_DIR/gen_client_config.sh" "$N"
    local CLI_CFG="${N}c1s5r5p-zoo.yml"
  fi
  local run_label="${LABEL}-N${N}c500"
  echo "  [$run_label] running..."
  bash "$SCRIPT_DIR/run_single_exp.sh" "$CFG" "$MODE" concurrent_500.yml "$run_label" "$RDIR" "$CLI_CFG" \
    > "$RDIR/${run_label}.runlog" 2>&1 || true

  local total=0
  local -a CPUS P50S P90S P99S
  for zi in 0 1 2 3 4; do
    local f="$RDIR/${run_label}-zoo$((zi+1)).res"
    local tp
    tp=$(grep -m1 "Mid throughput" "$f" 2>/dev/null | awk '{print $NF}')
    local cpu
    cpu=$(grep -m1 "server average" "$f" 2>/dev/null | awk '{print $NF}')
    if [ -z "$cpu" ]; then
      cpu=$(grep -m1 "server median" "$f" 2>/dev/null | awk '{print $NF}')
    fi
    local stats_line
    stats_line=$(grep "All-efficient-attempts *statistics" "$f" 2>/dev/null | head -1)
    local p50 p90 p99
    p50=$(awk '{for(i=1;i<=NF;i++) if($i=="50pct"){print $(i+1);exit}}' <<< "$stats_line")
    p90=$(awk '{for(i=1;i<=NF;i++) if($i=="90pct"){print $(i+1);exit}}' <<< "$stats_line")
    p99=$(awk '{for(i=1;i<=NF;i++) if($i=="99pct"){print $(i+1);exit}}' <<< "$stats_line")
    [ -z "$tp" ]  && tp=0
    [ -z "$cpu" ] && cpu=0
    [ -z "$p50" ] && p50=0
    [ -z "$p90" ] && p90=0
    [ -z "$p99" ] && p99=0
    CPUS[$zi]=$cpu
    P50S[$zi]=$p50
    P90S[$zi]=$p90
    P99S[$zi]=$p99
    total=$(awk -v t="$total" -v x="$tp" 'BEGIN{print t+x}')
  done

  local avg_cpu
  avg_cpu=$(awk -v a="${CPUS[0]}" -v b="${CPUS[1]}" -v c="${CPUS[2]}" -v d="${CPUS[3]}" -v e="${CPUS[4]}" \
               'BEGIN{printf "%.3f", (a+b+c+d+e)/5}')

  # zoo2 = index 1, zoo3 = index 2.
  LAST_N=$N
  LAST_TPUT=$total
  LAST_Z2_P50=${P50S[1]}; LAST_Z2_P90=${P90S[1]}; LAST_Z2_P99=${P99S[1]}
  LAST_Z3_P50=${P50S[2]}; LAST_Z3_P90=${P90S[2]}; LAST_Z3_P99=${P99S[2]}
  LAST_Z1_CPU=${CPUS[0]}; LAST_Z2_CPU=${CPUS[1]}; LAST_Z3_CPU=${CPUS[2]}
  LAST_Z4_CPU=${CPUS[3]}; LAST_Z5_CPU=${CPUS[4]}
  LAST_AVG_CPU=$avg_cpu
}

record_row() {
  local stopped="$1"
  echo "$LAST_N,$LAST_TPUT,$LAST_Z2_P50,$LAST_Z2_P90,$LAST_Z2_P99,$LAST_Z3_P50,$LAST_Z3_P90,$LAST_Z3_P99,$LAST_Z1_CPU,$LAST_Z2_CPU,$LAST_Z3_CPU,$LAST_Z4_CPU,$LAST_Z5_CPU,$LAST_AVG_CPU,$stopped" >> "$OUT_CSV"
  printf "    N=%s tput=%s zoo2_p50=%s p90=%s p99=%s zoo3_p50=%s avg_cpu=%s stopped=%s\n" \
    "$LAST_N" "$LAST_TPUT" "$LAST_Z2_P50" "$LAST_Z2_P90" "$LAST_Z2_P99" \
    "$LAST_Z3_P50" "$LAST_AVG_CPU" "$stopped"
}

tripped_stop() {
  # 1 if zoo2 p50 > stop_p50, else 0.
  awk -v v="$LAST_Z2_P50" -v s="$STOP_P50" 'BEGIN{print (v>s)?1:0}'
}

echo "=========================================="
echo "Adaptive sweep: $LABEL (cfg=$CFG mode=$MODE, pin=core ${SERVER_CORE_ID})"
echo "=========================================="

# 1) Baseline at N=1 (client co-located with leader at zoo2)
echo "  [baseline] running N=1..."
run_point 1
BASELINE_P50=$LAST_Z2_P50
bad=$(awk -v b="$BASELINE_P50" 'BEGIN{print (b<=0)?1:0}')
if [ "$bad" -eq 1 ]; then
  echo "  [baseline] ERROR: zoo2 p50 at N=1 is ${BASELINE_P50} (non-positive); aborting."
  exit 2
fi
STOP_P50=$(awk -v b="$BASELINE_P50" 'BEGIN{print 2*b}')
echo "  [baseline] zoo2 p50 at N=1 = ${BASELINE_P50}ms  -> stop_p50 = ${STOP_P50}ms"
record_row "baseline"

# 2) Initial probes at N=50, N=100.
declare -a probed_Ns=(50 100)
last_ok=1
first_stop=0
for N in "${probed_Ns[@]}"; do
  run_point "$N"
  hit=$(tripped_stop)
  record_row "$([ "$hit" -eq 1 ] && echo "stop" || echo "ok")"
  if [ "$hit" -eq 1 ]; then
    first_stop="$N"
    break
  fi
  last_ok="$N"
done

# 3) If neither tripped, extend.
if [ "$first_stop" -eq 0 ]; then
  for N in "${UP_SEQ[@]}"; do
    run_point "$N"
    hit=$(tripped_stop)
    record_row "$([ "$hit" -eq 1 ] && echo "stop" || echo "ok")"
    if [ "$hit" -eq 1 ]; then
      first_stop="$N"
      break
    fi
    last_ok="$N"
  done
fi

# 4) Bisect between last_ok and first_stop if we found a stop.
if [ "$first_stop" -ne 0 ]; then
  lo="$last_ok"; hi="$first_stop"
  while [ $((hi - lo)) -gt "$BISECT_TOL" ]; do
    mid=$(( (lo + hi) / 2 ))
    run_point "$mid"
    hit=$(tripped_stop)
    record_row "$([ "$hit" -eq 1 ] && echo "bisect-stop" || echo "bisect-ok")"
    if [ "$hit" -eq 1 ]; then
      hi="$mid"
    else
      lo="$mid"
    fi
  done
  echo "  [bisect] converged: last unsaturated=$lo, first saturated=$hi"
else
  echo "  [warning] did not hit saturation in sweep range; extend UP_SEQ"
fi

# 5) Pretty table.
echo ""
echo "=========================================="
echo "Summary table for $LABEL (stop_p50=${STOP_P50}ms)"
echo "=========================================="
awk -F, 'NR==1 {
  printf "%4s %8s %7s %7s %7s %7s %7s %7s %7s %7s %7s %7s %7s %7s %s\n",
    "N","tput","z2_p50","z2_p90","z2_p99","z3_p50","z3_p90","z3_p99",
    "z1_cpu","z2_cpu","z3_cpu","z4_cpu","z5_cpu","avg_cpu","note"
  next
}
{
  printf "%4s %8s %7s %7s %7s %7s %7s %7s %7s %7s %7s %7s %7s %7s %s\n",
    $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15
}' "$OUT_CSV"
echo ""
echo "CSV written to $OUT_CSV"
