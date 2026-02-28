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
# Output: TSV with columns: concurrency, total_throughput, per_process_throughputs

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
echo -e "concurrency\ttotal_throughput\th1\th2\th3\th4\th5"

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

    # Calculate total
    total=$(echo "$h1 + $h2 + $h3 + $h4 + $h5" | bc 2>/dev/null || echo "0")

    echo -e "${conc}\t${total}\t${h1}\t${h2}\t${h3}\t${h4}\t${h5}"

    # If throughput dropped significantly, we may have passed the peak
    # Continue anyway to get full data
done
