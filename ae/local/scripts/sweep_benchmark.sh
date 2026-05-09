#!/bin/bash
# sweep_benchmark.sh - Run a concurrency sweep for a given backend/mode combination.
#
# Usage:
#   ./sweep_benchmark.sh <docker_image> <mode_config> [extra_server_args]
#
# Example:
#   ./sweep_benchmark.sh jetpack-etcd none_etcd.yml
#   ./sweep_benchmark.sh jetpack-etcd rule_etcd.yml "-m 100"
#   ./sweep_benchmark.sh jetpack-mongodb none_mongodb.yml
#
# Output: TSV with columns:
#   concurrency, total_throughput, h1..h5,
#   fp_attempted, fp_succeeded, fp_rate,
#   cpu_leader_avg, queue_depth_avg,
#   status, error_summary, log_path, retry_count
#
# Status values:
#   OK       - docker exited 0, all 5 processes reported throughput > 0
#   PARTIAL  - docker exited 0 but some processes reported 0 throughput
#   FAILED   - docker exited non-zero or total throughput is 0 after all retries

set -euo pipefail

DOCKER_IMAGE="${1:?Usage: $0 <docker_image> <mode_config> [extra_args]}"
MODE_CONFIG="${2:?Usage: $0 <docker_image> <mode_config> [extra_args]}"
EXTRA_ARGS="${3:-}"

SITE_CONFIG="60c1s5r5p.yml"
CLIENT_CONFIG="client_open.yml"
LATENCY_MS=20
LATENCY_JITTER=0
TEST_DURATION=30
MAX_RETRIES=2

# Log directory: docs/sweep_2026-02-28/logs/<image>_<mode>/
# Derive a short name from image and mode for the log subdirectory
IMAGE_SHORT=$(echo "$DOCKER_IMAGE" | sed 's/.*\///' | tr ':' '_')
MODE_SHORT=$(basename "$MODE_CONFIG" .yml)
LOG_DIR="docs/sweep_2026-02-28/logs/${IMAGE_SHORT}_${MODE_SHORT}"
mkdir -p "$LOG_DIR"

# Concurrency values to sweep. The AE wrapper (ae/local/run.sh) can
# override this via AE_CONC_OVERRIDE="1 60 150 500" in the environment
# so the AE matrix in run.sh drives the sweep instead of
# the upstream-development default below.
if [ -n "${AE_CONC_OVERRIDE:-}" ]; then
    # shellcheck disable=SC2206  # word-split is intentional
    CONCURRENCIES=($AE_CONC_OVERRIDE)
else
    CONCURRENCIES=(1 5 10 25 50 75 100 150 200 300 400)
fi

echo "# Sweep: image=$DOCKER_IMAGE mode=$MODE_CONFIG extra_args='$EXTRA_ARGS'"
echo "# Site config: $SITE_CONFIG (60 clients)"
echo "# Latency: ${LATENCY_MS}ms, Duration: ${TEST_DURATION}s"
echo "# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# Max retries per point: $MAX_RETRIES"
echo -e "concurrency\ttotal_throughput\th1\th2\th3\th4\th5\tfp_attempted\tfp_succeeded\tfp_rate\tcpu_leader_avg\tqueue_depth_avg\tstatus\terror_summary\tlog_path\tretry_count"

# extract_metrics <output_text>
# Sets variables: h1..h5, total, fp_attempted, fp_succeeded, fp_rate,
#                 cpu_leader_avg, queue_depth_avg
extract_metrics() {
    local output="$1"

    # Extract per-process throughput
    h1=$(echo "$output" | grep "h1:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h2=$(echo "$output" | grep "h2:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h3=$(echo "$output" | grep "h3:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h4=$(echo "$output" | grep "h4:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h5=$(echo "$output" | grep "h5:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")

    # Calculate total throughput
    total=$(echo "$h1 + $h2 + $h3 + $h4 + $h5" | bc 2>/dev/null || echo "0")

    # Extract fastpath statistics (sum across processes)
    fp_attempted=0
    fp_succeeded=0
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

    # Extract CPU usage leader average
    cpu_sum=0
    cpu_n=0
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

    # Extract queue depth average
    qd_sum=0
    qd_n=0
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

# classify_status <exit_code> <total_throughput> <h1> <h2> <h3> <h4> <h5>
# Sets variables: status, error_summary
classify_run() {
    local exit_code="$1"
    local total_tp="$2"
    shift 2
    local procs=("$@")

    if [ "$exit_code" -ne 0 ]; then
        status="FAILED"
        error_summary="docker_exit_${exit_code}"
        return
    fi

    # Check if total throughput is zero (string comparison handles bc output)
    local is_zero
    is_zero=$(echo "$total_tp == 0" | bc 2>/dev/null || echo "1")
    if [ "$is_zero" -eq 1 ]; then
        status="FAILED"
        error_summary="zero_throughput_all_processes"
        return
    fi

    # Check for partial failure: some processes reported 0
    local zero_count=0
    for p in "${procs[@]}"; do
        local pz
        pz=$(echo "$p == 0" | bc 2>/dev/null || echo "1")
        if [ "$pz" -eq 1 ]; then
            zero_count=$((zero_count + 1))
        fi
    done

    if [ "$zero_count" -gt 0 ]; then
        status="PARTIAL"
        error_summary="${zero_count}_of_5_processes_zero"
    else
        status="OK"
        error_summary=""
    fi
}

# detect_failure_signature <output_text> <exit_code>
# Appends concrete failure info to error_summary
detect_failure_signature() {
    local output="$1"
    local exit_code="$2"

    # Look for common failure patterns in output
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

# read_proc_stat: Read aggregate CPU jiffies from /proc/stat
# Returns: "user nice system idle iowait irq softirq steal" on stdout
read_proc_stat() {
    awk '/^cpu / {print $2, $3, $4, $5, $6, $7, $8, $9}' /proc/stat
}

# compute_cpu_pct: Given two /proc/stat snapshots, compute CPU usage percentage
# Usage: compute_cpu_pct "before_stats" "after_stats"
compute_cpu_pct() {
    local before="$1"
    local after="$2"
    read -r u1 n1 s1 i1 w1 q1 f1 t1 <<< "$before"
    read -r u2 n2 s2 i2 w2 q2 f2 t2 <<< "$after"
    local total1=$((u1 + n1 + s1 + i1 + w1 + q1 + f1 + t1))
    local total2=$((u2 + n2 + s2 + i2 + w2 + q2 + f2 + t2))
    local idle1=$((i1 + w1))
    local idle2=$((i2 + w2))
    local total_diff=$((total2 - total1))
    local idle_diff=$((idle2 - idle1))
    if [ "$total_diff" -le 0 ]; then
        echo "0"
        return
    fi
    echo "scale=4; 100.0 * (1.0 - $idle_diff / $total_diff)" | bc 2>/dev/null || echo "0"
}

for conc in "${CONCURRENCIES[@]}"; do
    best_status="FAILED"
    best_output=""
    best_exit_code=1
    best_ext_cpu=""
    retry_count=0

    for attempt in $(seq 0 "$MAX_RETRIES"); do
        log_file="${LOG_DIR}/conc${conc}_attempt${attempt}.log"

        # Snapshot host CPU before benchmark for external measurement
        cpu_before=$(read_proc_stat)

        # Run benchmark, capturing exit code
        exit_code=0
        output=$(docker run --rm --privileged \
            -e SITE_CONFIG="$SITE_CONFIG" \
            -e MODE_CONFIG="$MODE_CONFIG" \
            -e CLIENT_CONFIG="$CLIENT_CONFIG" \
            -e CONCURRENT_CONFIG="concurrent_${conc}.yml" \
            -e LATENCY_MS="$LATENCY_MS" \
            -e LATENCY_JITTER="$LATENCY_JITTER" \
            -e TEST_DURATION="$TEST_DURATION" \
            -e SERVER_EXTRA_ARGS="$EXTRA_ARGS" \
            "$DOCKER_IMAGE" benchmark 2>&1) || exit_code=$?

        # Snapshot host CPU after benchmark
        cpu_after=$(read_proc_stat)
        ext_cpu=$(compute_cpu_pct "$cpu_before" "$cpu_after")

        # Save full output to log file
        {
            echo "# Attempt: $attempt of $MAX_RETRIES"
            echo "# Concurrency: $conc"
            echo "# Docker exit code: $exit_code"
            echo "# Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "---"
            echo "$output"
        } > "$log_file"

        # Extract metrics from this attempt
        extract_metrics "$output"
        classify_run "$exit_code" "$total" "$h1" "$h2" "$h3" "$h4" "$h5"

        # Keep best attempt: OK > PARTIAL > FAILED
        if [ "$status" = "OK" ]; then
            best_status="OK"
            best_output="$output"
            best_exit_code="$exit_code"
            best_ext_cpu="$ext_cpu"
            retry_count="$attempt"
            break
        elif [ "$status" = "PARTIAL" ] && [ "$best_status" = "FAILED" ]; then
            best_status="PARTIAL"
            best_output="$output"
            best_exit_code="$exit_code"
            best_ext_cpu="$ext_cpu"
            retry_count="$attempt"
        elif [ "$best_status" = "FAILED" ]; then
            best_output="$output"
            best_exit_code="$exit_code"
            best_ext_cpu="$ext_cpu"
            retry_count="$attempt"
        fi

        # Only retry if the run failed or had zero throughput
        if [ "$status" = "OK" ] || [ "$status" = "PARTIAL" ]; then
            break
        fi

        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
            echo "# Retry $((attempt + 1))/$MAX_RETRIES for concurrency=$conc (status=$status)" >&2
            sleep 5
        fi
    done

    # Re-extract final metrics from best attempt
    extract_metrics "$best_output"
    classify_run "$best_exit_code" "$total" "$h1" "$h2" "$h3" "$h4" "$h5"
    detect_failure_signature "$best_output" "$best_exit_code"

    # Fallback: if in-process CPU is 0 (e.g., original mode), use external measurement
    if [ "$cpu_leader_avg" = "0" ] && [ -n "$best_ext_cpu" ] && [ "$best_ext_cpu" != "0" ]; then
        cpu_leader_avg="$best_ext_cpu"
    fi

    # Log path relative to repo root
    log_path="${LOG_DIR}/conc${conc}_attempt${retry_count}.log"

    echo -e "${conc}\t${total}\t${h1}\t${h2}\t${h3}\t${h4}\t${h5}\t${fp_attempted}\t${fp_succeeded}\t${fp_rate}\t${cpu_leader_avg}\t${queue_depth_avg}\t${status}\t${error_summary}\t${log_path}\t${retry_count}"
done
