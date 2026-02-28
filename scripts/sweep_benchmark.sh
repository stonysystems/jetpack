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
#   cpu_leader_avg, queue_depth_avg

set -euo pipefail

DOCKER_IMAGE="${1:?Usage: $0 <docker_image> <mode_config> [extra_args]}"
MODE_CONFIG="${2:?Usage: $0 <docker_image> <mode_config> [extra_args]}"
EXTRA_ARGS="${3:-}"

SITE_CONFIG="60c1s5r5p.yml"
CLIENT_CONFIG="client_open.yml"
LATENCY_MS=20
LATENCY_JITTER=0
TEST_DURATION=30

# Concurrency values to sweep
CONCURRENCIES=(1 5 10 25 50 75 100 150 200 300 400)

echo "# Sweep: image=$DOCKER_IMAGE mode=$MODE_CONFIG extra_args='$EXTRA_ARGS'"
echo "# Site config: $SITE_CONFIG (60 clients)"
echo "# Latency: ${LATENCY_MS}ms, Duration: ${TEST_DURATION}s"
echo -e "concurrency\ttotal_throughput\th1\th2\th3\th4\th5\tfp_attempted\tfp_succeeded\tfp_rate\tcpu_leader_avg\tqueue_depth_avg"

for conc in "${CONCURRENCIES[@]}"; do
    # Run benchmark
    output=$(docker run --rm --privileged \
        -e SITE_CONFIG="$SITE_CONFIG" \
        -e MODE_CONFIG="$MODE_CONFIG" \
        -e CLIENT_CONFIG="$CLIENT_CONFIG" \
        -e CONCURRENT_CONFIG="concurrent_${conc}.yml" \
        -e LATENCY_MS="$LATENCY_MS" \
        -e LATENCY_JITTER="$LATENCY_JITTER" \
        -e TEST_DURATION="$TEST_DURATION" \
        -e SERVER_EXTRA_ARGS="$EXTRA_ARGS" \
        "$DOCKER_IMAGE" benchmark 2>&1) || true

    # Extract per-process throughput
    h1=$(echo "$output" | grep "h1:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h2=$(echo "$output" | grep "h2:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h3=$(echo "$output" | grep "h3:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h4=$(echo "$output" | grep "h4:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h5=$(echo "$output" | grep "h5:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")

    # Calculate total throughput
    total=$(echo "$h1 + $h2 + $h3 + $h4 + $h5" | bc 2>/dev/null || echo "0")

    # Extract fastpath statistics (sum across processes)
    # Log line: "Fastpath statistics attempted X successed Y rate(pct) Z.ZZ ..."
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

    # Extract CPU usage leader average (average across processes that report it)
    # Log line: "Cpu-usage-leaders ave X.XXXX count N"
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

    # Extract queue depth average (average across processes that report it)
    # Log line: "Queue-depth ave X.XXXX count N"
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

    echo -e "${conc}\t${total}\t${h1}\t${h2}\t${h3}\t${h4}\t${h5}\t${fp_attempted}\t${fp_succeeded}\t${fp_rate}\t${cpu_leader_avg}\t${queue_depth_avg}"

    # If throughput dropped significantly, we may have passed the peak
    # Continue anyway to get full data
done
