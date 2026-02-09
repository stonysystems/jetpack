#!/bin/bash
# run-etcd-test.sh - Entrypoint for Jetpack + etcd Docker integration testing.
#
# Usage:
#   ./run-etcd-test.sh single    # Single-process: embedded etcd + 1 Jetpack server + 1 client
#   ./run-etcd-test.sh multi     # Multi-process: embedded etcd + 3 Jetpack servers + 1 client
#   ./run-etcd-test.sh etcd-only # Start only the embedded etcd server (for external use)
#   ./run-etcd-test.sh bash      # Interactive shell
#
# Environment variables:
#   ETCD_ENDPOINTS  - External etcd endpoint (default: start embedded etcd at 127.0.0.1:2379)
#   TEST_DURATION   - Test duration in seconds (default: 10)
#   JETPACK_DIR     - Jetpack installation directory (default: /jetpack)

set -euo pipefail

JETPACK_DIR="${JETPACK_DIR:-/jetpack}"
TEST_DURATION="${TEST_DURATION:-10}"
ETCD_DATA_DIR="/tmp/etcd-data"
ETCD_LOG="/tmp/etcd.log"
LOG_DIR="/tmp/jetpack-logs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

cleanup() {
    log_info "Cleaning up..."
    # Kill any Jetpack server processes
    pkill -f deptran_server 2>/dev/null || true
    # Kill embedded etcd if we started it
    pkill -f "etcd --name" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT

start_embedded_etcd() {
    if [ -n "${ETCD_ENDPOINTS:-}" ]; then
        log_info "Using external etcd at $ETCD_ENDPOINTS"
        return 0
    fi

    log_info "Starting embedded etcd server..."
    rm -rf "$ETCD_DATA_DIR"
    mkdir -p "$ETCD_DATA_DIR"

    etcd \
        --name etcd-test \
        --listen-client-urls http://127.0.0.1:2379 \
        --advertise-client-urls http://127.0.0.1:2379 \
        --listen-peer-urls http://127.0.0.1:2380 \
        --initial-advertise-peer-urls http://127.0.0.1:2380 \
        --initial-cluster "etcd-test=http://127.0.0.1:2380" \
        --data-dir "$ETCD_DATA_DIR" \
        > "$ETCD_LOG" 2>&1 &

    ETCD_PID=$!

    # Wait for etcd to be ready
    for i in $(seq 1 30); do
        if etcdctl endpoint health --endpoints=http://127.0.0.1:2379 >/dev/null 2>&1; then
            log_info "etcd is ready (PID=$ETCD_PID)"
            return 0
        fi
        sleep 0.5
    done

    log_error "etcd failed to start within 15 seconds"
    cat "$ETCD_LOG"
    return 1
}

verify_etcd_rw() {
    local endpoint="${ETCD_ENDPOINTS:-http://127.0.0.1:2379}"
    log_info "Verifying etcd read/write at $endpoint ..."

    # Write a test key
    if ! etcdctl --endpoints="$endpoint" put JetPack/test/hello world >/dev/null 2>&1; then
        log_error "etcd write failed"
        return 1
    fi

    # Read it back
    local val
    val=$(etcdctl --endpoints="$endpoint" get JetPack/test/hello --print-value-only 2>/dev/null)
    if [ "$val" != "world" ]; then
        log_error "etcd read verification failed: expected 'world', got '$val'"
        return 1
    fi

    # Cleanup
    etcdctl --endpoints="$endpoint" del JetPack/test/hello >/dev/null 2>&1

    log_info "etcd read/write verification passed"
    return 0
}

run_single_process_test() {
    log_info "=== Single-Process Test ==="
    log_info "Config: 1 client, 1 server (3 replicas), 1 partition"
    log_info "Duration: ${TEST_DURATION}s"

    start_embedded_etcd
    verify_etcd_rw

    mkdir -p "$LOG_DIR"

    local config_site="${JETPACK_DIR}/config/1c1s3r1p.yml"
    local config_mode="${JETPACK_DIR}/config/none_etcd.yml"
    local server_bin="${JETPACK_DIR}/build/deptran_server"

    if [ ! -x "$server_bin" ]; then
        log_error "Jetpack server binary not found at $server_bin"
        log_warn "Build may have failed. Check build logs."
        return 1
    fi

    # Start 3 server replicas + 1 client in the same process
    # The run.py script handles multi-process orchestration, but for a
    # single-process test we launch the server directly.
    local processes=("s101" "s201" "s301" "c01")
    local pids=()
    local base_port=38200

    for proc in "${processes[@]}"; do
        local port=$((base_port + ${#pids[@]}))
        log_info "Starting process $proc on port $port"
        "$server_bin" \
            -f "$config_site" \
            -f "$config_mode" \
            -P "$proc" \
            -p "$port" \
            -d "$TEST_DURATION" \
            -r "$LOG_DIR" \
            > "$LOG_DIR/proc-${proc}.log" 2>&1 &
        pids+=($!)
    done

    log_info "Waiting for ${#pids[@]} processes to complete..."

    local exit_code=0
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}" 2>/dev/null; then
            log_warn "Process ${processes[$i]} (PID ${pids[$i]}) exited with non-zero status"
            exit_code=1
        fi
    done

    if [ $exit_code -eq 0 ]; then
        log_info "=== Single-Process Test PASSED ==="
    else
        log_warn "=== Single-Process Test completed with warnings ==="
        log_info "Check logs in $LOG_DIR for details"
    fi

    return $exit_code
}

run_etcd_only() {
    log_info "=== Starting etcd server only ==="
    start_embedded_etcd
    verify_etcd_rw
    log_info "etcd is running at http://127.0.0.1:2379"
    log_info "Press Ctrl+C to stop"
    wait
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
MODE="${1:-single}"

case "$MODE" in
    single)
        run_single_process_test
        ;;
    etcd-only)
        run_etcd_only
        ;;
    bash|sh)
        start_embedded_etcd || true
        exec bash
        ;;
    *)
        echo "Usage: $0 {single|etcd-only|bash}"
        echo ""
        echo "Modes:"
        echo "  single    - Embedded etcd + Jetpack single-process test"
        echo "  etcd-only - Start only the embedded etcd server"
        echo "  bash      - Interactive shell with etcd running"
        exit 1
        ;;
esac
