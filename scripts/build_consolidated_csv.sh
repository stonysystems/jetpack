#!/bin/bash
# build_consolidated_csv.sh - Build consolidated audit CSV from canonical sweep TSVs.
#
# Usage:
#   ./scripts/build_consolidated_csv.sh > docs/sweep_2026-02-28/consolidated.csv
#
# Reads all 9 canonical TSV files and produces a single CSV with the
# audit schema specified in TODO.md.

set -euo pipefail

SWEEP_DIR="docs/sweep_2026-02-28"

# Canonical files: backend, mode, extra_args, tsv_file
CANONICAL=(
    "etcd,original,,etcd_original.tsv"
    "etcd,fastpath-100,-m 100,etcd_fastpath100.tsv"
    "etcd,adaptive,,etcd_adaptive.tsv"
    "mongodb,original,,mongodb_original.tsv"
    "mongodb,fastpath-100,-m 100,mongodb_fastpath100.tsv"
    "mongodb,adaptive,,mongodb_adaptive.tsv"
    "zookeeper,original,,zookeeper_original.tsv"
    "zookeeper,fastpath-100,-m 100,zookeeper_fastpath100.tsv"
    "zookeeper,adaptive,,zookeeper_adaptive.tsv"
)

# Print CSV header
echo "backend,mode,extra_args,concurrency,run_id,status,total_throughput,h1,h2,h3,h4,h5,cpu_all_avg,cpu_leader_avg,leader_queue_depth_avg,fastpath_attempt_rate,fastpath_success_rate,original_path_rate,error_count,error_summary,log_path"

run_id=1

for entry in "${CANONICAL[@]}"; do
    IFS=',' read -r backend mode extra_args tsv_file <<< "$entry"
    tsv_path="${SWEEP_DIR}/${tsv_file}"

    if [ ! -f "$tsv_path" ]; then
        echo "# WARNING: $tsv_path not found" >&2
        continue
    fi

    while IFS=$'\t' read -r conc total h1 h2 h3 h4 h5 fp_attempted fp_succeeded fp_rate cpu_leader_avg queue_depth_avg rest; do
        # Skip comment and header lines
        [[ "$conc" =~ ^# ]] && continue
        [[ "$conc" == "concurrency" ]] && continue

        # Determine status
        local_status=""
        error_summary=""
        log_path=""

        # Check if this TSV has status columns (new format)
        if [ -n "$rest" ]; then
            local_status=$(echo "$rest" | cut -f1)
            error_summary=$(echo "$rest" | cut -f2)
            log_path=$(echo "$rest" | cut -f3)
        fi

        # Infer status for old-format TSVs
        is_zero=$(echo "$total == 0" | bc 2>/dev/null || echo "0")
        if [ "$is_zero" -eq 1 ]; then
            local_status="${local_status:-FAILED}"
            error_summary="${error_summary:-pre_classification_zero_throughput}"
        else
            local_status="${local_status:-OK}"
        fi

        # CPU: use NA if zero for original mode (pre-instrumentation data)
        cpu_all_avg="NA"  # Not measured separately from leader
        if [ "$mode" = "original" ]; then
            # Original mode had no CPU metrics before the instrumentation fix
            if [ "$cpu_leader_avg" = "0" ] || [ -z "$cpu_leader_avg" ]; then
                cpu_leader_avg="NA"
            fi
        else
            if [ "$cpu_leader_avg" = "0" ] || [ -z "$cpu_leader_avg" ]; then
                cpu_leader_avg="NA"
            fi
        fi

        # Queue depth: NA if zero for original mode
        if [ "$queue_depth_avg" = "0" ] || [ -z "$queue_depth_avg" ]; then
            queue_depth_avg="NA"
        fi

        # Fastpath rates
        if [ "$fp_attempted" -gt 0 ] 2>/dev/null; then
            fastpath_attempt_rate="$fp_rate"
            fastpath_success_rate="$fp_rate"
            # Original path rate = 100 - fastpath success rate
            original_path_rate=$(echo "scale=2; 100 - $fp_rate" | bc 2>/dev/null || echo "NA")
        else
            if [ "$mode" = "original" ]; then
                fastpath_attempt_rate="0"
                fastpath_success_rate="0"
                original_path_rate="100"
            else
                fastpath_attempt_rate="NA"
                fastpath_success_rate="NA"
                original_path_rate="NA"
            fi
        fi

        # Error count: 0 for OK, 1 for failures
        if [ "$local_status" = "OK" ]; then
            error_count=0
        else
            error_count=1
        fi

        # Escape commas in error_summary
        error_summary_escaped=$(echo "$error_summary" | tr ',' ';')

        echo "${backend},${mode},${extra_args},${conc},${run_id},${local_status},${total},${h1},${h2},${h3},${h4},${h5},${cpu_all_avg},${cpu_leader_avg},${queue_depth_avg},${fastpath_attempt_rate},${fastpath_success_rate},${original_path_rate},${error_count},${error_summary_escaped},${log_path}"
        run_id=$((run_id + 1))
    done < "$tsv_path"
done
