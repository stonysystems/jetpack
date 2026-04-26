#!/bin/bash
# run_max_throughput_regression.sh — regression suite that runs four
# adaptive throughput sweeps (vanilla raft, jp-raft-fp100, jp-raft-adaptive,
# curp) and asserts each one's peak throughput under the p90<=1000ms SLO is
# at or above a floor. Exits non-zero on the first miss, prints a summary
# table at the end either way.
#
# Each sweep takes ~8-10 min, total ~35-45 min wall time.
#
# Usage:
#   SERVER_CORE_ID=17 ./run_max_throughput_regression.sh [<result_root>]
# Example:
#   SERVER_CORE_ID=17 ./run_max_throughput_regression.sh \
#       results/2026-04-26-regression-core17

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RESULT_ROOT="${1:-$REPO_DIR/results/$(date +%Y-%m-%d)-regression-core17}"
mkdir -p "$RESULT_ROOT"

export SERVER_CORE_ID="${SERVER_CORE_ID:-17}"

# (label, cfg, mode, peak-tput floor)
SWEEPS=(
  "raft|none_raft.yml|0|15500"
  "jp-raft-fp100|rule_raft_merge_skip_pool.yml|100|14000"
  "jp-raft-adaptive|rule_raft_merge_skip_pool.yml|101|14000"
  "curp|none_curp.yml|200|14000"
)

echo "============================================================"
echo "Max-throughput regression"
echo "  result root: $RESULT_ROOT"
echo "  server core: $SERVER_CORE_ID"
echo "  sweeps:      ${#SWEEPS[@]}"
echo "============================================================"

declare -A PEAKS
declare -A PEAKS_AT_N
declare -A FLOORS
PASS=()
FAIL=()

for spec in "${SWEEPS[@]}"; do
  IFS='|' read -r label cfg mode floor <<< "$spec"
  rdir="$RESULT_ROOT/$label"
  rlog="$RESULT_ROOT/$label.log"
  echo
  echo "------------------------------------------------------------"
  echo "[$label] cfg=$cfg mode=$mode floor=$floor"
  echo "------------------------------------------------------------"
  bash "$SCRIPT_DIR/run_adaptive_sweep.sh" "$label" "$cfg" "$mode" "$rdir" 2>&1 | tee "$rlog"
  csv="$rdir/${label}-adaptive.csv"
  if [[ ! -f "$csv" ]]; then
    echo "[$label] ERROR: $csv not found, marking FAIL"
    PEAKS[$label]=0
    PEAKS_AT_N[$label]=0
    FLOORS[$label]=$floor
    FAIL+=("$label")
    continue
  fi
  # Pick the row with the highest tput where zoo2_p90 (col 4) <= 1000.
  # CSV columns:
  # 1=N, 2=tput, 3=zoo2_p50, 4=zoo2_p90, ...
  read -r peak_n peak_tput < <(awk -F',' 'NR>1 && $2+0>0 && $4+0>0 && $4+0<=1000 {
        if ($2+0 > best) { best=$2+0; best_n=$1 }
      }
      END { if (best>0) print best_n, best; else print 0, 0 }' "$csv")
  PEAKS[$label]=${peak_tput:-0}
  PEAKS_AT_N[$label]=${peak_n:-0}
  FLOORS[$label]=$floor
  if awk "BEGIN { exit !(${peak_tput:-0} >= $floor) }"; then
    PASS+=("$label")
  else
    FAIL+=("$label")
  fi
done

echo
echo "============================================================"
echo "Regression summary (floor = ~5% below recent green baseline)"
echo "============================================================"
printf "%-20s %12s %12s %8s  %s\n" "label" "peak_tput" "at_N" "floor" "verdict"
for spec in "${SWEEPS[@]}"; do
  IFS='|' read -r label cfg mode floor <<< "$spec"
  verdict="PASS"
  for f in "${FAIL[@]}"; do
    if [[ "$f" == "$label" ]]; then verdict="FAIL"; fi
  done
  printf "%-20s %12.1f %12s %8s  %s\n" \
    "$label" "${PEAKS[$label]}" "${PEAKS_AT_N[$label]}" "${FLOORS[$label]}" "$verdict"
done

echo
if (( ${#FAIL[@]} > 0 )); then
  echo "FAIL: ${#FAIL[@]} of ${#SWEEPS[@]} sweep(s) below floor: ${FAIL[*]}"
  exit 1
fi
echo "PASS: all ${#SWEEPS[@]} sweep(s) above floor"
exit 0
