#!/bin/bash
# run_curp_data_sweep.sh
#
# Three-set data collection across the protocol/mode matrix used for the
# CURP paper figures.
#
# Set A: concurrency sweep (rw_1000000 uniform). Source for the
#        throughput-latency figure and for picking the fixed-N point used
#        by Sets B/C.
# Set B: key-range sweep at the per-protocol fixed-N (CPU ~50% on zoo2).
#        Source for the key-range -> avg-latency figure.
# Set C: zipf sweep at the same per-protocol fixed-N.
#        Source for the zipf -> {avg, p90, p99, fp-rate, success-rate}
#        figures and the latency CDF figure (per-cmd csv samples).
#
# Per run we drive scripts/run_single_exp.sh with the standard zoo
# 5-machine layout, c500 ongoing per client, 30 s duration. Parsed
# summary metrics are appended to per-set CSVs; the per-cmd csv files
# (one per replica per run) stay in place for downstream plotting.
#
# Usage:
#   SERVER_CORE_ID=17 ./run_curp_data_sweep.sh [<result_root>]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RESULT_ROOT="${1:-$REPO_DIR/results/$(date +%Y-%m-%d)-curp-data-sweep-core17}"
mkdir -p "$RESULT_ROOT"

export SERVER_CORE_ID="${SERVER_CORE_ID:-17}"
DURATION=30

# ---------------------------------------------------------------------
# Protocol/mode matrix.
# Each entry: label|cfg.yml|mode|n_grid (space-separated)
# n_grid sets the Set A concurrency points for this protocol; tuned for
# each family's known saturation range.
# ---------------------------------------------------------------------
declare -a PROTOS=(
  # Raft family — peak around N=75-150
  "raft|none_raft.yml|0|1 25 50 75 100 150"
  "jp-raft-fp0|rule_raft_merge_skip_pool.yml|0|1 25 50 75 100 150"
  "jp-raft-fp100|rule_raft_merge_skip_pool.yml|100|1 25 50 75 100 150"
  "jp-raft-adaptive|rule_raft_merge_skip_pool.yml|101|1 25 50 75 100 150"
  # Copilot family — peak around N=50-100
  "copilot|none_copilot.yml|0|1 25 50 75 100"
  "jp-copilot-fp0|rule_copilot.yml|0|1 25 50 75 100"
  "jp-copilot-fp100|rule_copilot.yml|100|1 25 50 75 100"
  "jp-copilot-adaptive|rule_copilot.yml|101|1 25 50 75 100"
  # Mencius family — peak around N=10-25 (small range)
  "mencius|none_mencius.yml|0|1 10 16 25 40"
  "jp-mencius-fp0|rule_mencius.yml|0|1 10 16 25 40"
  "jp-mencius-fp100|rule_mencius.yml|100|1 10 16 25 40"
  "jp-mencius-adaptive|rule_mencius.yml|101|1 10 16 25 40"
  # etcd family
  "etcd|none_etcd.yml|0|1 25 50 75 100"
  "jp-etcd-fp0|rule_etcd.yml|0|1 25 50 75 100"
  "jp-etcd-fp100|rule_etcd.yml|100|1 25 50 75 100"
  "jp-etcd-adaptive|rule_etcd.yml|101|1 25 50 75 100"
  # MongoDB family — peak around N=40
  "mongodb|none_mongodb.yml|0|1 25 40 60 80"
  "jp-mongodb-fp0|rule_mongodb.yml|0|1 25 40 60 80"
  "jp-mongodb-fp100|rule_mongodb.yml|100|1 25 40 60 80"
  "jp-mongodb-adaptive|rule_mongodb.yml|101|1 25 40 60 80"
  # Standalone
  "epaxos|none_epaxos_corrected.yml|0|1 50 100 150 200"
  "swiftpaxos|none_swiftpaxos.yml|0|1 25 50 75 100"
  "curp|none_curp.yml|200|1 25 50 75 100"
)

# Set B: key-range workloads (rw_<keys>.yml)
SET_B_WORKLOADS=(rw_1 rw_10 rw_100 rw_1000 rw_10000 rw_100000 rw_1000000)
# Set C: zipf workloads. rw_1000000 = uniform baseline (effective zipf=0).
SET_C_WORKLOADS=(rw_1000000 rw_zipf_0.5 rw_zipf_0.6 rw_zipf_0.7 rw_zipf_0.8 rw_zipf_0.9 rw_zipf_1)

# ---------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------

# Parse one (.res-file-set, run-label) and emit a summary CSV row.
# Output columns:
#   protocol,mode,workload,N,total_tput,z2_tput,z2_p50,z2_p90,z2_p99,
#   avg_z2_cpu_5h,fp_att,fp_succ,fp_eff,fp_rate,fp_eff_rate
parse_run() {
  local rdir="$1" run_label="$2" proto="$3" mode="$4" workload="$5" N="$6"
  local total_tput=0
  local z2_tput="" z2_p50="" z2_p90="" z2_p99=""
  local fp_att_total=0 fp_succ_total=0 fp_eff_total=0
  local cpu_sum=0 cpu_n=0
  for zi in 0 1 2 3 4; do
    local f="$rdir/${run_label}-zoo$((zi+1)).res"
    [ -f "$f" ] || continue
    local tp
    tp=$(grep -m1 "Mid throughput" "$f" 2>/dev/null | awk '{print $NF}')
    [ -z "$tp" ] && tp=0
    total_tput=$(awk -v t="$total_tput" -v x="$tp" 'BEGIN{print t+x}')
    local cpu
    cpu=$(grep -m1 "server average" "$f" 2>/dev/null | awk '{print $NF}')
    [ -z "$cpu" ] && cpu=$(grep -m1 "server median" "$f" 2>/dev/null | awk '{print $NF}')
    if [ -n "$cpu" ]; then
      cpu_sum=$(awk -v s="$cpu_sum" -v x="$cpu" 'BEGIN{print s+x}')
      cpu_n=$((cpu_n+1))
    fi
    local stats_line
    stats_line=$(grep "All-efficient-attempts *statistics" "$f" 2>/dev/null | head -1)
    local p50 p90 p99
    p50=$(awk '{for(i=1;i<=NF;i++) if($i=="50pct"){print $(i+1);exit}}' <<< "$stats_line")
    p90=$(awk '{for(i=1;i<=NF;i++) if($i=="90pct"){print $(i+1);exit}}' <<< "$stats_line")
    p99=$(awk '{for(i=1;i<=NF;i++) if($i=="99pct"){print $(i+1);exit}}' <<< "$stats_line")
    if [ "$zi" = "1" ]; then
      z2_tput="$tp"
      z2_p50="$p50"
      z2_p90="$p90"
      z2_p99="$p99"
    fi
    local fp_line
    fp_line=$(grep -m1 "Fastpath statistics" "$f" 2>/dev/null)
    if [ -n "$fp_line" ]; then
      local fp_att fp_succ fp_eff
      fp_att=$(awk '{for(i=1;i<=NF;i++) if($i=="attempted"){print $(i+1);exit}}' <<< "$fp_line")
      fp_succ=$(awk '{for(i=1;i<=NF;i++) if($i=="successed"){print $(i+1);exit}}' <<< "$fp_line")
      fp_eff=$(awk '{for(i=1;i<=NF;i++) if($i=="efficient_successed"){print $(i+1);exit}}' <<< "$fp_line")
      [ -z "$fp_att" ]  && fp_att=0
      [ -z "$fp_succ" ] && fp_succ=0
      [ -z "$fp_eff" ]  && fp_eff=0
      fp_att_total=$((fp_att_total + fp_att))
      fp_succ_total=$((fp_succ_total + fp_succ))
      fp_eff_total=$((fp_eff_total + fp_eff))
    fi
  done
  local avg_cpu="-1"
  if [ "$cpu_n" -gt 0 ]; then
    avg_cpu=$(awk -v s="$cpu_sum" -v n="$cpu_n" 'BEGIN{printf "%.3f", s/n}')
  fi
  local fp_rate=0 fp_eff_rate=0
  if [ "$fp_att_total" -gt 0 ]; then
    fp_rate=$(awk -v a="$fp_att_total" -v b="$fp_succ_total" 'BEGIN{printf "%.4f", b*100.0/a}')
    fp_eff_rate=$(awk -v a="$fp_att_total" -v b="$fp_eff_total" 'BEGIN{printf "%.4f", b*100.0/a}')
  fi
  echo "${proto},${mode},${workload},${N},${total_tput},${z2_tput:-0},${z2_p50:-0},${z2_p90:-0},${z2_p99:-0},${avg_cpu},${fp_att_total},${fp_succ_total},${fp_eff_total},${fp_rate},${fp_eff_rate}"
}

# Run a single (proto, cfg, mode, workload, N) point.
# Writes per-replica .res / .csv into RDIR; appends summary row to SUMMARY_CSV.
run_one() {
  local proto="$1" cfg="$2" mode="$3" workload="$4" N="$5" rdir="$6" summary_csv="$7"
  mkdir -p "$rdir"
  local run_label="${proto}-${workload}-N${N}c500"
  echo "  [$run_label] running..."
  # Generate the site config for this N if not pre-built.
  local cli_cfg="${N}c1s5r5p-zoo.yml"
  if [ ! -f "$REPO_DIR/config/$cli_cfg" ]; then
    if [ "$N" = "1" ]; then
      cli_cfg="1c1s5r5p-zoo2.yml"
      if [ ! -f "$REPO_DIR/config/$cli_cfg" ]; then
        bash "$SCRIPT_DIR/gen_client_config.sh" "$N"
      fi
    else
      bash "$SCRIPT_DIR/gen_client_config.sh" "$N"
    fi
  fi
  bash "$SCRIPT_DIR/run_single_exp.sh" "$cfg" "$mode" concurrent_500.yml \
        "$run_label" "$rdir" "$cli_cfg" \
        > "$rdir/${run_label}.runlog" 2>&1 || true
  parse_run "$rdir" "$run_label" "$proto" "$mode" "$workload" "$N" >> "$summary_csv"
}

# Pick the N from a per-protocol Set-A summary that maximizes throughput.
# Then pick the unsaturated N closest to ~50% z2 CPU.
# Emits "<peak_N> <peak_tput> <fixed_N> <fixed_cpu>".
pick_per_protocol() {
  local proto="$1" summary_csv="$2"
  awk -F',' -v p="$proto" '
    $1==p && $5+0>0 {
      tput=$5+0; cpu=$10+0; N=$4+0;
      if (tput > peak_tput) { peak_tput=tput; peak_N=N }
      # Track the N whose zoo2 CPU is closest to 50% (only positive cpu vals).
      if (cpu > 0) {
        diff = (cpu>50)? cpu-50 : 50-cpu
        if (best_n == 0 || diff < best_diff) { best_diff=diff; best_N=N; best_cpu=cpu }
      }
    }
    END {
      if (best_N==0) best_N = peak_N  # fallback
      printf "%d %.1f %d %.1f\n", peak_N, peak_tput, best_N, best_cpu
    }
  ' "$summary_csv"
}

cluster_kill() {
  (cd "$SCRIPT_DIR" && bash 98-kill.sh) &>/dev/null || true
}

# ---------------------------------------------------------------------
# Set A: concurrency sweep (uniform workload).
# ---------------------------------------------------------------------
SET_A_DIR="$RESULT_ROOT/set_a_throughput_latency"
SET_A_SUMMARY="$RESULT_ROOT/set_a_summary.csv"
mkdir -p "$SET_A_DIR"
echo "protocol,mode,workload,N,total_tput,z2_tput,z2_p50,z2_p90,z2_p99,avg_cpu_5h,fp_att,fp_succ,fp_eff,fp_rate,fp_eff_rate" > "$SET_A_SUMMARY"

echo "============================================================"
echo "Set A — concurrency sweep (rw_1000000)"
echo "============================================================"
cluster_kill
for entry in "${PROTOS[@]}"; do
  IFS='|' read -r proto cfg mode n_grid <<< "$entry"
  echo
  echo "  ---- $proto (cfg=$cfg mode=$mode) ----"
  for N in $n_grid; do
    run_one "$proto" "$cfg" "$mode" rw_1000000 "$N" "$SET_A_DIR" "$SET_A_SUMMARY"
  done
done

# ---------------------------------------------------------------------
# Derive per-protocol fixed N for Sets B and C: pick the Set A N whose
# zoo2 average CPU is closest to 50%. Fall back to peak N if no
# valid CPU reading is available.
# ---------------------------------------------------------------------
FIXED_N_FILE="$RESULT_ROOT/fixed_n_per_protocol.csv"
echo "protocol,peak_N,peak_tput,fixed_N,fixed_cpu" > "$FIXED_N_FILE"
declare -A FIXED_N
echo
echo "============================================================"
echo "Per-protocol fixed N (closest to 50% zoo2 CPU)"
echo "============================================================"
for entry in "${PROTOS[@]}"; do
  IFS='|' read -r proto cfg mode n_grid <<< "$entry"
  read -r peak_N peak_tput fixed_N fixed_cpu < <(pick_per_protocol "$proto" "$SET_A_SUMMARY")
  FIXED_N[$proto]=$fixed_N
  echo "  $proto: peak N=$peak_N tput=$peak_tput | fixed N=$fixed_N cpu=$fixed_cpu%"
  echo "$proto,$peak_N,$peak_tput,$fixed_N,$fixed_cpu" >> "$FIXED_N_FILE"
done

# ---------------------------------------------------------------------
# Set B: key-range sweep at fixed N.
# ---------------------------------------------------------------------
SET_B_DIR="$RESULT_ROOT/set_b_keyrange"
SET_B_SUMMARY="$RESULT_ROOT/set_b_summary.csv"
mkdir -p "$SET_B_DIR"
echo "protocol,mode,workload,N,total_tput,z2_tput,z2_p50,z2_p90,z2_p99,avg_cpu_5h,fp_att,fp_succ,fp_eff,fp_rate,fp_eff_rate" > "$SET_B_SUMMARY"

echo
echo "============================================================"
echo "Set B — key-range sweep at fixed N"
echo "============================================================"
cluster_kill
for entry in "${PROTOS[@]}"; do
  IFS='|' read -r proto cfg mode n_grid <<< "$entry"
  fixed_n_for_proto="${FIXED_N[$proto]:-50}"
  echo
  echo "  ---- $proto (cfg=$cfg mode=$mode) at N=$fixed_n_for_proto ----"
  for wl in "${SET_B_WORKLOADS[@]}"; do
    run_one "$proto" "$cfg" "$mode" "$wl" "$fixed_n_for_proto" "$SET_B_DIR" "$SET_B_SUMMARY"
  done
done

# ---------------------------------------------------------------------
# Set C: zipf sweep at fixed N.
# ---------------------------------------------------------------------
SET_C_DIR="$RESULT_ROOT/set_c_zipf"
SET_C_SUMMARY="$RESULT_ROOT/set_c_summary.csv"
mkdir -p "$SET_C_DIR"
echo "protocol,mode,workload,N,total_tput,z2_tput,z2_p50,z2_p90,z2_p99,avg_cpu_5h,fp_att,fp_succ,fp_eff,fp_rate,fp_eff_rate" > "$SET_C_SUMMARY"

echo
echo "============================================================"
echo "Set C — zipf sweep at fixed N"
echo "============================================================"
cluster_kill
for entry in "${PROTOS[@]}"; do
  IFS='|' read -r proto cfg mode n_grid <<< "$entry"
  fixed_n_for_proto="${FIXED_N[$proto]:-50}"
  echo
  echo "  ---- $proto (cfg=$cfg mode=$mode) at N=$fixed_n_for_proto ----"
  for wl in "${SET_C_WORKLOADS[@]}"; do
    run_one "$proto" "$cfg" "$mode" "$wl" "$fixed_n_for_proto" "$SET_C_DIR" "$SET_C_SUMMARY"
  done
done

echo
echo "============================================================"
echo "Done. Output:"
echo "  $RESULT_ROOT/set_a_throughput_latency/  + set_a_summary.csv"
echo "  $RESULT_ROOT/set_b_keyrange/            + set_b_summary.csv"
echo "  $RESULT_ROOT/set_c_zipf/                + set_c_summary.csv"
echo "  $RESULT_ROOT/fixed_n_per_protocol.csv"
echo "============================================================"
