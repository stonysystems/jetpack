#!/bin/bash
# run-zookeeper-test.sh - Entrypoint for Jetpack + ZooKeeper Docker integration testing.
#
# Usage:
#   ./run-zookeeper-test.sh single       # Single-process: embedded ZooKeeper + 3 Jetpack servers + 1 client
#   ./run-zookeeper-test.sh multi        # Multi-process: embedded ZooKeeper + 5 servers + 5 clients + latency
#   ./run-zookeeper-test.sh recovery     # Recovery: 3-node ZooKeeper ensemble, kill leader, measure recovery
#   ./run-zookeeper-test.sh zookeeper-only # Start only the embedded ZooKeeper server (for external use)
#   ./run-zookeeper-test.sh bash         # Interactive shell
#
# Environment variables:
#   ZOOKEEPER_ENDPOINTS - External ZooKeeper URI (default: start embedded ZK at 127.0.0.1:2181)
#   TEST_DURATION       - Test duration in seconds (default: 10)
#   JETPACK_DIR         - Jetpack installation directory (default: /jetpack)
#   LATENCY_MS          - Simulated inter-server latency in ms (default: 5, multi mode only)
#   LATENCY_JITTER      - Latency jitter in ms (default: 2, multi mode only)

set -euo pipefail

JETPACK_DIR="${JETPACK_DIR:-/jetpack}"
TEST_DURATION="${TEST_DURATION:-10}"
LATENCY_MS="${LATENCY_MS:-5}"
LATENCY_JITTER="${LATENCY_JITTER:-2}"
ZOOKEEPER_PORT="${ZOOKEEPER_PORT:-2181}"
ZOOKEEPER_HOME="${ZOOKEEPER_HOME:-/opt/zookeeper}"
ZOOKEEPER_DATA_DIR="/tmp/zookeeper-data"
ZOOKEEPER_LOG="/tmp/zookeeper.log"
LOG_DIR="/tmp/jetpack-logs"

# Recovery mode state
ENSEMBLE_IPS=("127.0.0.1" "127.0.0.2" "127.0.0.3")
ENSEMBLE_PIDS=()
ENSEMBLE_DATA_DIRS=()

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
    # Kill embedded ZooKeeper if we started it
    pkill -f "org.apache.zookeeper" 2>/dev/null || true
    # Remove tc latency rules if they were applied
    remove_latency 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT

start_embedded_zookeeper() {
    if [ -n "${ZOOKEEPER_ENDPOINTS:-}" ]; then
        log_info "Using external ZooKeeper at $ZOOKEEPER_ENDPOINTS"
        return 0
    fi

    log_info "Starting embedded ZooKeeper server..."
    rm -rf "$ZOOKEEPER_DATA_DIR"
    mkdir -p "$ZOOKEEPER_DATA_DIR"

    # Create minimal ZooKeeper configuration
    cat > /tmp/zoo.cfg <<EOF
tickTime=2000
dataDir=$ZOOKEEPER_DATA_DIR
clientPort=$ZOOKEEPER_PORT
admin.enableServer=false
EOF

    # Start ZooKeeper server
    "${ZOOKEEPER_HOME}/bin/zkServer.sh" start /tmp/zoo.cfg > "$ZOOKEEPER_LOG" 2>&1

    # Wait for ZooKeeper to be ready
    for i in $(seq 1 30); do
        if echo ruok | nc -w 2 127.0.0.1 "$ZOOKEEPER_PORT" 2>/dev/null | grep -q imok; then
            log_info "ZooKeeper is ready (port=$ZOOKEEPER_PORT)"
            return 0
        fi
        sleep 0.5
    done

    log_error "ZooKeeper failed to start within 15 seconds"
    cat "$ZOOKEEPER_LOG" || true
    return 1
}

# --- Latency simulation (for multi-process tests) ---

setup_latency() {
    local ips=("127.0.0.1" "127.0.0.2" "127.0.0.3" "127.0.0.4" "127.0.0.5")
    log_info "Setting up latency: ${LATENCY_MS}ms +/- ${LATENCY_JITTER}ms"

    # Add netem qdisc on loopback
    tc qdisc add dev lo root handle 1: prio bands 4 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 2>/dev/null || \
    tc qdisc replace dev lo root handle 1: prio bands 4 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0

    tc qdisc add dev lo parent 1:4 handle 40: netem delay "${LATENCY_MS}ms" "${LATENCY_JITTER}ms" 2>/dev/null || \
    tc qdisc replace dev lo parent 1:4 handle 40: netem delay "${LATENCY_MS}ms" "${LATENCY_JITTER}ms"

    for ip in "${ips[@]}"; do
        tc filter add dev lo parent 1:0 protocol ip u32 match ip dst "$ip" flowid 1:4 2>/dev/null || true
    done
    log_info "Latency simulation active on loopback"
}

remove_latency() {
    tc qdisc del dev lo root 2>/dev/null || true
}

# --- ZooKeeper ensemble for recovery tests ---

start_zookeeper_ensemble() {
    log_info "Starting 3-node ZooKeeper ensemble..."
    local base_client_port=2181
    local base_peer_port=2888
    local base_election_port=3888

    for i in 0 1 2; do
        local ip="${ENSEMBLE_IPS[$i]}"
        local data_dir="/tmp/zk-ensemble-${i}"
        local client_port=$((base_client_port + i))
        local cfg="/tmp/zoo-${i}.cfg"

        rm -rf "$data_dir"
        mkdir -p "$data_dir"
        echo "$((i + 1))" > "$data_dir/myid"
        ENSEMBLE_DATA_DIRS+=("$data_dir")

        cat > "$cfg" <<EOF
tickTime=2000
initLimit=5
syncLimit=2
dataDir=$data_dir
clientPort=$client_port
admin.enableServer=false
server.1=${ENSEMBLE_IPS[0]}:${base_peer_port}:${base_election_port}
server.2=${ENSEMBLE_IPS[1]}:$((base_peer_port + 1)):$((base_election_port + 1))
server.3=${ENSEMBLE_IPS[2]}:$((base_peer_port + 2)):$((base_election_port + 2))
EOF

        "${ZOOKEEPER_HOME}/bin/zkServer.sh" start "$cfg" > "/tmp/zk-ensemble-${i}.log" 2>&1
        local pid
        pid=$(cat "$data_dir/zookeeper_server.pid" 2>/dev/null || echo "")
        ENSEMBLE_PIDS+=("$pid")
        log_info "  Node $((i + 1)): ip=$ip, port=$client_port, pid=$pid"
    done

    # Wait for ensemble to elect a leader
    log_info "Waiting for ZooKeeper ensemble to stabilize..."
    for attempt in $(seq 1 30); do
        local leaders=0
        for i in 0 1 2; do
            local port=$((base_client_port + i))
            local mode
            mode=$(echo srvr | nc -w 2 "${ENSEMBLE_IPS[$i]}" "$port" 2>/dev/null | grep "Mode:" | awk '{print $2}' || echo "")
            if [ "$mode" = "leader" ]; then
                leaders=$((leaders + 1))
            fi
        done
        if [ "$leaders" -ge 1 ]; then
            log_info "ZooKeeper ensemble ready ($leaders leader(s))"
            return 0
        fi
        sleep 1
    done

    log_error "ZooKeeper ensemble failed to elect leader within 30 seconds"
    return 1
}

get_zookeeper_leader() {
    local base_client_port=2181
    for i in 0 1 2; do
        local port=$((base_client_port + i))
        local mode
        mode=$(echo srvr | nc -w 2 "${ENSEMBLE_IPS[$i]}" "$port" 2>/dev/null | grep "Mode:" | awk '{print $2}' || echo "")
        if [ "$mode" = "leader" ]; then
            echo "${ENSEMBLE_IPS[$i]}:$port"
            return 0
        fi
    done
    echo ""
    return 1
}

kill_zookeeper_node() {
    local target_ip="$1"
    for i in 0 1 2; do
        if [ "${ENSEMBLE_IPS[$i]}" = "$target_ip" ]; then
            local pid="${ENSEMBLE_PIDS[$i]}"
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                log_info "Killing ZooKeeper node $((i + 1)) (ip=$target_ip, pid=$pid) with SIGKILL"
                kill -9 "$pid" 2>/dev/null || true
                return 0
            fi
        fi
    done
    log_error "ZooKeeper node at $target_ip not found"
    return 1
}

wait_zookeeper_new_leader() {
    local killed_ip="$1"
    local start_ns
    start_ns=$(date +%s%N)
    log_info "Waiting for new ZooKeeper leader (killed: $killed_ip)..."

    for attempt in $(seq 1 60); do
        local base_client_port=2181
        for i in 0 1 2; do
            if [ "${ENSEMBLE_IPS[$i]}" = "$killed_ip" ]; then
                continue
            fi
            local port=$((base_client_port + i))
            local mode
            mode=$(echo srvr | nc -w 2 "${ENSEMBLE_IPS[$i]}" "$port" 2>/dev/null | grep "Mode:" | awk '{print $2}' || echo "")
            if [ "$mode" = "leader" ]; then
                local end_ns
                end_ns=$(date +%s%N)
                local duration_ms=$(( (end_ns - start_ns) / 1000000 ))
                log_info "New ZooKeeper leader elected: ${ENSEMBLE_IPS[$i]}:$port (${duration_ms}ms)"
                return 0
            fi
        done
        sleep 0.5
    done

    log_error "No new ZooKeeper leader within 30 seconds"
    return 1
}

# --- Test modes ---

run_single_process_test() {
    log_info "=== Single-process test ==="
    start_embedded_zookeeper

    mkdir -p "$LOG_DIR"
    local config="${JETPACK_DIR}/config/1c1s3r1p.yml"
    local binary="${JETPACK_DIR}/build/deptran_server"

    log_info "Starting Jetpack (zookeeper mode, config=$config, duration=${TEST_DURATION}s)..."
    "$binary" \
        -f "$config" \
        -d "$TEST_DURATION" \
        -t 30 \
        -T 2 \
        -P "zookeeper" \
        -r "zookeeper" \
        2>&1 | tee "$LOG_DIR/jetpack-single.log"

    local exit_code=${PIPESTATUS[0]}
    if [ "$exit_code" -eq 0 ]; then
        log_info "=== Single-process test PASSED ==="
    else
        log_error "=== Single-process test FAILED (exit=$exit_code) ==="
    fi
    return "$exit_code"
}

run_multi_process_test() {
    log_info "=== Multi-process test ==="
    start_embedded_zookeeper
    setup_latency

    mkdir -p "$LOG_DIR"
    local config="${JETPACK_DIR}/config/5c1s5r1p_zookeeper.yml"
    local binary="${JETPACK_DIR}/build/deptran_server"

    log_info "Starting Jetpack (zookeeper mode, 5 servers + 5 clients, latency=${LATENCY_MS}ms)..."
    "$binary" \
        -f "$config" \
        -d "$TEST_DURATION" \
        -t 30 \
        -T 2 \
        -P "zookeeper" \
        -r "zookeeper" \
        2>&1 | tee "$LOG_DIR/jetpack-multi.log"

    local exit_code=${PIPESTATUS[0]}
    remove_latency

    if [ "$exit_code" -eq 0 ]; then
        log_info "=== Multi-process test PASSED ==="
    else
        log_error "=== Multi-process test FAILED (exit=$exit_code) ==="
    fi
    return "$exit_code"
}

run_recovery_test() {
    log_info "=== Recovery test ==="
    start_zookeeper_ensemble

    mkdir -p "$LOG_DIR"
    local config="${JETPACK_DIR}/config/1c1s3r1p.yml"
    local failover_config="${JETPACK_DIR}/config/failover_zookeeper.yml"
    local binary="${JETPACK_DIR}/build/deptran_server"

    # Get the current leader
    local leader
    leader=$(get_zookeeper_leader)
    local leader_ip="${leader%%:*}"
    log_info "Current ZooKeeper leader: $leader"

    # Start Jetpack with failover config
    log_info "Starting Jetpack with failover config..."
    "$binary" \
        -f "$config" \
        -f "$failover_config" \
        -d "$TEST_DURATION" \
        -t 30 \
        -T 2 \
        -P "zookeeper" \
        -r "zookeeper" \
        2>&1 | tee "$LOG_DIR/jetpack-recovery.log" &
    local jetpack_pid=$!

    # Let Jetpack run for the configured run_interval
    sleep 5

    # Kill the ZooKeeper leader
    kill_zookeeper_node "$leader_ip"

    # Wait for new leader
    wait_zookeeper_new_leader "$leader_ip"

    # Wait for Jetpack to finish
    wait "$jetpack_pid" 2>/dev/null
    local exit_code=$?

    # Check for recovery completion in logs
    if grep -q "JetpackRecoveryEntry" "$LOG_DIR/jetpack-recovery.log" 2>/dev/null; then
        log_info "Jetpack recovery detected in logs"
    else
        log_warn "No Jetpack recovery entry found in logs"
    fi

    # Check surviving ZooKeeper nodes
    local surviving=0
    for i in 0 1 2; do
        local port=$((2181 + i))
        if echo ruok | nc -w 2 "${ENSEMBLE_IPS[$i]}" "$port" 2>/dev/null | grep -q imok; then
            surviving=$((surviving + 1))
        fi
    done
    log_info "Surviving ZooKeeper nodes: $surviving/3"

    if [ "$exit_code" -eq 0 ]; then
        log_info "=== Recovery test PASSED ==="
    else
        log_error "=== Recovery test FAILED (exit=$exit_code) ==="
    fi
    return "$exit_code"
}

# --- Main ---

MODE="${1:-single}"

case "$MODE" in
    single)
        run_single_process_test
        ;;
    multi)
        run_multi_process_test
        ;;
    recovery)
        run_recovery_test
        ;;
    zookeeper-only)
        start_embedded_zookeeper
        log_info "ZooKeeper running on port $ZOOKEEPER_PORT. Press Ctrl+C to stop."
        tail -f "$ZOOKEEPER_LOG" 2>/dev/null || sleep infinity
        ;;
    bash)
        start_embedded_zookeeper || true
        exec /bin/bash
        ;;
    *)
        log_error "Unknown mode: $MODE"
        log_error "Usage: $0 {single|multi|recovery|zookeeper-only|bash}"
        exit 1
        ;;
esac
