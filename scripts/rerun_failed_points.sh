#!/bin/bash
# rerun_failed_points.sh - Rerun only the 12 known failed concurrency points.
#
# Uses the same retry/classification logic as sweep_benchmark.sh but only
# runs the specific failed data points from the FAILURE_LEDGER.
#
# Output: TSV rows (same format as sweep_benchmark.sh) plus saved logs.

set -euo pipefail

SITE_CONFIG="60c1s5r5p.yml"
CLIENT_CONFIG="client_open.yml"
LATENCY_MS=20
LATENCY_JITTER=0
TEST_DURATION=30
MAX_RETRIES=2
LOG_BASE="docs/sweep_2026-02-28/logs"
RESULTS_DIR="docs/sweep_2026-02-28/rerun_$(date +%Y%m%d)"
mkdir -p "$RESULTS_DIR"

# Source the functions from sweep_benchmark.sh by extracting them
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# The 12 failed points: image|mode_config|extra_args|concurrency
FAILED_POINTS=(
    "jetpack-etcd|rule_etcd.yml|-m 100|50|etcd_fastpath100"
    "jetpack-etcd|rule_etcd.yml|-m 100|75|etcd_fastpath100"
    "jetpack-etcd|rule_etcd.yml|-m 100|300|etcd_fastpath100"
    "jetpack-etcd|rule_etcd.yml||150|etcd_adaptive"
    "jetpack-etcd|rule_etcd.yml||300|etcd_adaptive"
    "jetpack-mongodb|none_mongodb.yml||50|mongodb_original"
    "jetpack-mongodb|none_mongodb.yml||75|mongodb_original"
    "jetpack-mongodb|rule_mongodb.yml|-m 100|50|mongodb_fastpath100"
    "jetpack-mongodb|rule_mongodb.yml||5|mongodb_adaptive"
    "jetpack-mongodb|rule_mongodb.yml||200|mongodb_adaptive"
    "jetpack-zookeeper|rule_zookeeper.yml|-m 100|150|zookeeper_fastpath100"
    "jetpack-zookeeper|rule_zookeeper.yml|-m 100|300|zookeeper_fastpath100"
)

# Functions (same as sweep_benchmark.sh)
extract_metrics() {
    local output="$1"
    h1=$(echo "$output" | grep "h1:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h2=$(echo "$output" | grep "h2:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h3=$(echo "$output" | grep "h3:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h4=$(echo "$output" | grep "h4:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h5=$(echo "$output" | grep "h5:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    total=$(echo "$h1 + $h2 + $h3 + $h4 + $h5" | bc 2>/dev/null || echo "0")
    fp_attempted=0; fp_succeeded=0
    for h in h1 h2 h3 h4 h5; do
        fp_line=$(echo "$output" | grep "${h}:.*Fastpath statistics" || true)
        if [ -n "$fp_line" ]; then
            a=$(echo "$fp_line" | grep -oP 'attempted \K\d+' || echo "0")
            s=$(echo "$fp_line" | grep -oP 'successed \K\d+' | head -1 || echo "0")
            fp_attempted=$((fp_attempted + a))
            fp_succeeded=$((fp_succeeded + s))
        fi
    done
    if [ "$fp_attempted" -gt 0 ]; then
        fp_rate=$(echo "scale=2; $fp_succeeded * 100.0 / $fp_attempted" | bc 2>/dev/null || echo "0")
    else
        fp_rate="0"
    fi
    cpu_sum=0; cpu_n=0
    for h in h1 h2 h3 h4 h5; do
        cpu_line=$(echo "$output" | grep "${h}:.*Cpu-usage-leaders" || true)
        if [ -n "$cpu_line" ]; then
            c=$(echo "$cpu_line" | grep -oP 'ave \K[\d.]+' || echo "")
            if [ -n "$c" ] && [ "$c" != "-1.0000" ]; then
                cpu_sum=$(echo "$cpu_sum + $c" | bc 2>/dev/null || echo "$cpu_sum")
                cpu_n=$((cpu_n + 1))
            fi
        fi
    done
    if [ "$cpu_n" -gt 0 ]; then
        cpu_leader_avg=$(echo "scale=4; $cpu_sum / $cpu_n" | bc 2>/dev/null || echo "0")
    else
        cpu_leader_avg="0"
    fi
    qd_sum=0; qd_n=0
    for h in h1 h2 h3 h4 h5; do
        qd_line=$(echo "$output" | grep "${h}:.*Queue-depth" || true)
        if [ -n "$qd_line" ]; then
            q=$(echo "$qd_line" | grep -oP 'ave \K[\d.]+' || echo "")
            if [ -n "$q" ] && [ "$q" != "-1.0000" ]; then
                qd_sum=$(echo "$qd_sum + $q" | bc 2>/dev/null || echo "$qd_sum")
                qd_n=$((qd_n + 1))
            fi
        fi
    done
    if [ "$qd_n" -gt 0 ]; then
        queue_depth_avg=$(echo "scale=4; $qd_sum / $qd_n" | bc 2>/dev/null || echo "0")
    else
        queue_depth_avg="0"
    fi
}

classify_run() {
    local exit_code="$1" total_tp="$2"; shift 2; local procs=("$@")
    if [ "$exit_code" -ne 0 ]; then
        status="FAILED"; error_summary="docker_exit_${exit_code}"; return
    fi
    local is_zero; is_zero=$(echo "$total_tp == 0" | bc 2>/dev/null || echo "1")
    if [ "$is_zero" -eq 1 ]; then
        status="FAILED"; error_summary="zero_throughput_all_processes"; return
    fi
    local zero_count=0
    for p in "${procs[@]}"; do
        local pz; pz=$(echo "$p == 0" | bc 2>/dev/null || echo "1")
        if [ "$pz" -eq 1 ]; then zero_count=$((zero_count + 1)); fi
    done
    if [ "$zero_count" -gt 0 ]; then
        status="PARTIAL"; error_summary="${zero_count}_of_5_processes_zero"
    else
        status="OK"; error_summary=""
    fi
}

detect_failure_signature() {
    local output="$1" exit_code="$2"
    if echo "$output" | grep -qi "out of memory\|OOM\|Cannot allocate memory"; then
        error_summary="${error_summary};OOM"
    fi
    if echo "$output" | grep -qi "too many open files\|EMFILE"; then
        error_summary="${error_summary};fd_exhaustion"
    fi
    if echo "$output" | grep -qi "connection refused\|Connection reset"; then
        error_summary="${error_summary};connection_failure"
    fi
    if echo "$output" | grep -qi "Segmentation fault\|SIGSEGV\|core dumped"; then
        error_summary="${error_summary};crash_segfault"
    fi
    if echo "$output" | grep -qi "timeout\|timed out"; then
        error_summary="${error_summary};timeout"
    fi
    if [ -z "$output" ]; then
        error_summary="${error_summary};empty_output"
    elif ! echo "$output" | grep -q "Mid throughput"; then
        error_summary="${error_summary};no_benchmark_output"
    fi
}

echo "# Rerun of failed benchmark points"
echo "# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# Git commit: $(git rev-parse --short HEAD)"
echo "# Max retries: $MAX_RETRIES"
echo -e "dataset\tconcurrency\ttotal_throughput\th1\th2\th3\th4\th5\tfp_attempted\tfp_succeeded\tfp_rate\tcpu_leader_avg\tqueue_depth_avg\tstatus\terror_summary\tlog_path\tretry_count"

for entry in "${FAILED_POINTS[@]}"; do
    IFS='|' read -r docker_image mode_config extra_args conc dataset <<< "$entry"

    LOG_DIR="${LOG_BASE}/${dataset}_rerun"
    mkdir -p "$LOG_DIR"

    echo "# Running: $dataset conc=$conc (image=$docker_image mode=$mode_config extra='$extra_args')" >&2

    best_status="FAILED"
    best_output=""
    best_exit_code=1
    retry_count=0

    for attempt in $(seq 0 "$MAX_RETRIES"); do
        log_file="${LOG_DIR}/conc${conc}_attempt${attempt}.log"
        exit_code=0
        output=$(docker run --rm --privileged \
            -e SITE_CONFIG="$SITE_CONFIG" \
            -e MODE_CONFIG="$mode_config" \
            -e CLIENT_CONFIG="$CLIENT_CONFIG" \
            -e CONCURRENT_CONFIG="concurrent_${conc}.yml" \
            -e LATENCY_MS="$LATENCY_MS" \
            -e LATENCY_JITTER="$LATENCY_JITTER" \
            -e TEST_DURATION="$TEST_DURATION" \
            -e SERVER_EXTRA_ARGS="$extra_args" \
            "$docker_image" benchmark 2>&1) || exit_code=$?

        {
            echo "# Attempt: $attempt of $MAX_RETRIES"
            echo "# Dataset: $dataset"
            echo "# Concurrency: $conc"
            echo "# Docker exit code: $exit_code"
            echo "# Image: $docker_image"
            echo "# Mode: $mode_config"
            echo "# Extra args: $extra_args"
            echo "# Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "---"
            echo "$output"
        } > "$log_file"

        extract_metrics "$output"
        classify_run "$exit_code" "$total" "$h1" "$h2" "$h3" "$h4" "$h5"

        if [ "$status" = "OK" ]; then
            best_status="OK"; best_output="$output"; best_exit_code="$exit_code"
            retry_count="$attempt"; break
        elif [ "$status" = "PARTIAL" ] && [ "$best_status" = "FAILED" ]; then
            best_status="PARTIAL"; best_output="$output"; best_exit_code="$exit_code"
            retry_count="$attempt"
        elif [ "$best_status" = "FAILED" ]; then
            best_output="$output"; best_exit_code="$exit_code"
            retry_count="$attempt"
        fi

        if [ "$status" = "OK" ] || [ "$status" = "PARTIAL" ]; then break; fi

        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
            echo "#   Retry $((attempt + 1))/$MAX_RETRIES (status=$status)" >&2
            sleep 5
        fi
    done

    extract_metrics "$best_output"
    classify_run "$best_exit_code" "$total" "$h1" "$h2" "$h3" "$h4" "$h5"
    detect_failure_signature "$best_output" "$best_exit_code"
    log_path="${LOG_DIR}/conc${conc}_attempt${retry_count}.log"

    echo -e "${dataset}\t${conc}\t${total}\t${h1}\t${h2}\t${h3}\t${h4}\t${h5}\t${fp_attempted}\t${fp_succeeded}\t${fp_rate}\t${cpu_leader_avg}\t${queue_depth_avg}\t${status}\t${error_summary}\t${log_path}\t${retry_count}"
done
