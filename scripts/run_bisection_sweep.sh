#!/bin/bash
# run_bisection_sweep.sh — Sweep client counts for each protocol at
# concurrent=500 until saturation. Records per-point: per-host tp, per-host
# CPU (server median core1), max/avg CPU, p50 at peak, fast-path stats.
#
# Stop criterion per protocol: max server CPU >= 99% OR per-host p50 > 2x c1 baseline.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RDIR="${1:-results/2026-04-16-bisection}"
mkdir -p "$RDIR"

CLIENT_NS=(30 40 45 50 55 60 70 80 90 100)

# proto_cfg mode label
PROTOS=(
  "none_raft.yml 0 raft"
  "rule_raft.yml 100 jp-raft-fp100"
  "rule_raft.yml 101 jp-raft-adaptive"
  "none_swiftpaxos.yml 0 swiftpaxos"
  "none_epaxos_corrected.yml 0 epaxos"
)

# Baseline p50 for each protocol at c=1 (ms). Used as stop criterion:
# p50 > 2 * baseline triggers stop.
declare -A P50_BASE
P50_BASE["raft"]=85
P50_BASE["jp-raft-fp100"]=42
P50_BASE["jp-raft-adaptive"]=42
P50_BASE["swiftpaxos"]=42
P50_BASE["epaxos"]=42

OUT_SUMMARY="$RDIR/summary.csv"
echo "proto,N,total_tput,max_cpu,avg_cpu,zoo1_tp,zoo2_tp,zoo3_tp,zoo4_tp,zoo5_tp,zoo1_cpu,zoo2_cpu,zoo3_cpu,zoo4_cpu,zoo5_cpu,zoo1_p50,zoo4_p50" > "$OUT_SUMMARY"

for proto_line in "${PROTOS[@]}"; do
  read -r cfg mode label <<< "$proto_line"
  baseline=${P50_BASE[$label]:-80}
  stop_p50=$(awk -v b="$baseline" 'BEGIN {print 2*b}')
  echo ""
  echo "=========================================="
  echo "Protocol: $label  (stop if max CPU>=99 or p50>${stop_p50}ms)"
  echo "=========================================="
  for N in "${CLIENT_NS[@]}"; do
    CLI_CFG="${N}c1s5r5p-zoo.yml"
    if [ ! -f "$REPO_DIR/config/$CLI_CFG" ]; then
      echo "  [$label-N$N] skip, no $CLI_CFG"; continue
    fi
    run_label="${label}-N${N}c500"
    echo "  [$run_label] running..."
    bash "$SCRIPT_DIR/run_single_exp.sh" "$cfg" "$mode" concurrent_500.yml "$run_label" "$RDIR" "$CLI_CFG" > "$RDIR/${run_label}.runlog" 2>&1
    # Gather stats
    total=0; max_cpu=0; sum_cpu=0; n_cpu=0
    declare -a TPS CPUS P50S
    for zi in 0 1 2 3 4; do
      # Per-host file names use the 1-indexed display name (zoo1..zoo5).
      f="$RDIR/${run_label}-zoo$((zi+1)).res"
      tp=$(grep -m1 "Mid throughput" "$f" 2>/dev/null | awk '{print $NF}')
      cpu=$(grep -m1 "server median" "$f" 2>/dev/null | awk '{print $NF}')
      p50=$(grep "All-efficient.*statistics" "$f" 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="50pct") {print $(i+1); exit}}')
      [ -z "$tp" ] && tp=0
      [ -z "$cpu" ] && cpu=0
      [ -z "$p50" ] && p50=0
      TPS[$zi]=$tp; CPUS[$zi]=$cpu; P50S[$zi]=$p50
      total=$(awk -v t="$total" -v x="$tp" 'BEGIN {print t+x}')
      max_cpu=$(awk -v m="$max_cpu" -v x="$cpu" 'BEGIN {if (x>m) print x; else print m}')
      sum_cpu=$(awk -v s="$sum_cpu" -v x="$cpu" 'BEGIN {print s+x}')
      n_cpu=$((n_cpu+1))
    done
    avg_cpu=$(awk -v s="$sum_cpu" -v n="$n_cpu" 'BEGIN {if (n>0) print s/n; else print 0}')
    # Report avg across 5 hosts. Each per-host value is the median of its
    # mid-10s core-1 /proc/stat samples (see src/deptran/s_main.cc getUsage).
    # The "bottleneck replica" max_cpu is still used for saturation detection —
    # saturation is inherently a per-replica property — but we don't report
    # it as the headline CPU number.
    echo "    total_tput=$total  CPU_5hosts_avg=$avg_cpu  (bottleneck=$max_cpu)"
    echo "    per-host tp: zoo1=${TPS[0]} zoo2=${TPS[1]} zoo3=${TPS[2]} zoo4=${TPS[3]} zoo5=${TPS[4]}"
    echo "    per-host cpu(mid10s-median): zoo1=${CPUS[0]} zoo2=${CPUS[1]} zoo3=${CPUS[2]} zoo4=${CPUS[3]} zoo5=${CPUS[4]}"
    echo "    per-host p50: zoo1=${P50S[0]} zoo4=${P50S[3]}"
    echo "$label,$N,$total,$max_cpu,$avg_cpu,${TPS[0]},${TPS[1]},${TPS[2]},${TPS[3]},${TPS[4]},${CPUS[0]},${CPUS[1]},${CPUS[2]},${CPUS[3]},${CPUS[4]},${P50S[0]},${P50S[3]}" >> "$OUT_SUMMARY"
    # Stop criterion uses max_cpu >= 99% — saturation is a per-replica
    # condition; the avg can stay low while one replica pins (e.g. etcd,
    # where only zoo1 runs the connection pool).
    hit_cpu=$(awk -v m="$max_cpu" 'BEGIN {print (m>=99)?1:0}')
    hit_p50=0
    for zi in 0 1 2 3 4; do
      val=${P50S[$zi]}
      h=$(awk -v v="$val" -v s="$stop_p50" 'BEGIN {print (v>s)?1:0}')
      if [ "$h" -eq 1 ]; then hit_p50=1; break; fi
    done
    if [ "$hit_cpu" -eq 1 ] || [ "$hit_p50" -eq 1 ]; then
      echo "    [$run_label] STOP (bottleneck replica pinned=$hit_cpu, p50 breach=$hit_p50)"
      break
    fi
  done
done

echo ""
echo "Summary written to $OUT_SUMMARY"
