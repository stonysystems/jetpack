#!/bin/bash
# run_tier1_batch.sh — Sequential core-17 adaptive sweep across the 5
# scalable protocols + etcd. Each protocol produces its own results dir
# and per-protocol CSV, sized to be pasted into the core-17 report.
#
# Usage:
#   ./run_tier1_batch.sh <date>
# Example:
#   ./run_tier1_batch.sh 2026-04-20

set -uo pipefail

DATE="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

export SERVER_CORE_ID=17

# label  cfg  mode
PROTOS=(
  "raft             none_raft.yml             0"
  "swiftpaxos       none_swiftpaxos.yml       0"
  "epaxos           none_epaxos_corrected.yml 0"
  "jp-raft-fp100    rule_raft.yml             100"
  "jp-raft-adaptive rule_raft.yml             101"
  "etcd             none_etcd.yml             0"
)

for line in "${PROTOS[@]}"; do
  read -r label cfg mode <<< "$line"
  RDIR="$REPO_DIR/results/${DATE}-${label}-core17"
  echo ""
  echo "=========================================="
  echo "Tier 1 batch: $label  ($cfg, -m $mode)"
  echo "Results dir: $RDIR"
  echo "=========================================="
  bash "$SCRIPT_DIR/run_adaptive_sweep.sh" "$label" "$cfg" "$mode" "$RDIR" \
    2>&1 | tee "$REPO_DIR/results/${DATE}-tier1-batch-${label}.log" || {
      echo "  [$label] sweep failed — continuing with next protocol"
    }
done

echo ""
echo "=========================================="
echo "Tier 1 batch done. Result dirs under $REPO_DIR/results/${DATE}-*-core17/"
echo "=========================================="
