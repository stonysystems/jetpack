#!/bin/bash
# run_full_sweep.sh - Run all 9 backend/mode sweeps and regenerate canonical artifacts.
#
# This runs sweep_benchmark.sh for each of the 9 backend/mode combinations,
# saving results as canonical TSV files under docs/sweep_2026-02-28/.
#
# After all sweeps complete, regenerates Markdown tables and consolidated CSV.
#
# Usage:
#   ./scripts/run_full_sweep.sh          # run all 9 cases
#   ./scripts/run_full_sweep.sh etcd     # run only etcd cases (3 modes)

set -euo pipefail

SWEEP_DIR="docs/sweep_2026-02-28"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP_SCRIPT="${SCRIPT_DIR}/sweep_benchmark.sh"

# Define all 9 sweep cases: image|mode_config|extra_args|output_name
CASES=(
    "jetpack-etcd|none_etcd.yml||etcd_original"
    "jetpack-etcd|rule_etcd.yml|-m 100|etcd_fastpath100"
    "jetpack-etcd|rule_etcd.yml||etcd_adaptive"
    "jetpack-mongodb|none_mongodb.yml||mongodb_original"
    "jetpack-mongodb|rule_mongodb.yml|-m 100|mongodb_fastpath100"
    "jetpack-mongodb|rule_mongodb.yml||mongodb_adaptive"
    "jetpack-zookeeper|none_zookeeper.yml||zookeeper_original"
    "jetpack-zookeeper|rule_zookeeper.yml|-m 100|zookeeper_fastpath100"
    "jetpack-zookeeper|rule_zookeeper.yml||zookeeper_adaptive"
)

# Filter by backend if specified
FILTER="${1:-}"

failed=0
succeeded=0

for case_spec in "${CASES[@]}"; do
    IFS='|' read -r image mode extra name <<< "$case_spec"

    # Apply filter if provided
    if [ -n "$FILTER" ] && [[ "$name" != ${FILTER}* ]]; then
        continue
    fi

    tsv_file="${SWEEP_DIR}/${name}.tsv"

    echo "========================================" >&2
    echo "Running: $name (image=$image mode=$mode extra='$extra')" >&2
    echo "Output: $tsv_file" >&2
    echo "========================================" >&2

    if "$SWEEP_SCRIPT" "$image" "$mode" "$extra" > "$tsv_file"; then
        echo "  DONE: $name" >&2
        succeeded=$((succeeded + 1))
    else
        echo "  WARNING: $name sweep exited with error (data may be partial)" >&2
        failed=$((failed + 1))
    fi
done

echo "" >&2
echo "Sweep complete: $succeeded succeeded, $failed failed" >&2

# Regenerate Markdown tables
if [ -f "${SCRIPT_DIR}/tsv_to_md.sh" ]; then
    echo "Regenerating Markdown tables..." >&2
    bash "${SCRIPT_DIR}/tsv_to_md.sh" "${SWEEP_DIR}"/*.tsv
    echo "  Done" >&2
fi

# Regenerate consolidated CSV
if [ -f "${SCRIPT_DIR}/build_consolidated_csv.sh" ]; then
    echo "Regenerating consolidated CSV..." >&2
    bash "${SCRIPT_DIR}/build_consolidated_csv.sh" > "${SWEEP_DIR}/consolidated.csv"
    echo "  Done" >&2
fi

echo "All artifacts regenerated." >&2
