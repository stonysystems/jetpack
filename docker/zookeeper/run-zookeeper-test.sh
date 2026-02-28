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
#   ZOOKEEPER_ENDPOINTS    - External ZooKeeper URI (default: start embedded ZK at 127.0.0.1:2181)
#   TEST_DURATION          - Test duration in seconds (default: 10)
#   JETPACK_DIR            - Jetpack installation directory (default: /jetpack)
#   LATENCY_MS             - Simulated inter-server latency in ms (default: 5, multi mode only)
#   LATENCY_JITTER         - Latency jitter in ms (default: 2, multi mode only)
#   RECOVERY_LATENCY_MS    - One-way latency for recovery test WAN mode in ms (default: 0 = single-process)
#   RECOVERY_LATENCY_JITTER - Jitter for recovery test WAN mode in ms (default: 0)

set -euo pipefail

JETPACK_DIR="${JETPACK_DIR:-/jetpack}"
TEST_DURATION="${TEST_DURATION:-30}"
LATENCY_MS="${LATENCY_MS:-20}"
LATENCY_JITTER="${LATENCY_JITTER:-0}"
ZOOKEEPER_PORT="${ZOOKEEPER_PORT:-2181}"
SERVER_EXTRA_ARGS="${SERVER_EXTRA_ARGS:-}"
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
4lw.commands.whitelist=ruok,srvr,stat,mntr
EOF

    # Start ZooKeeper server
    "${ZOOKEEPER_HOME}/bin/zkServer.sh" start /tmp/zoo.cfg > "$ZOOKEEPER_LOG" 2>&1

    # Wait for ZooKeeper to be ready (try nc first, fall back to bash /dev/tcp)
    for i in $(seq 1 30); do
        local response=""
        if command -v nc &>/dev/null; then
            response=$(echo ruok | nc -w 2 127.0.0.1 "$ZOOKEEPER_PORT" 2>/dev/null || true)
        else
            response=$(echo ruok | timeout 2 bash -c "cat > /dev/tcp/127.0.0.1/$ZOOKEEPER_PORT; cat" 2>/dev/null || true)
        fi
        if echo "$response" | grep -q imok; then
            log_info "ZooKeeper is ready (port=$ZOOKEEPER_PORT)"
            return 0
        fi
        # Also try zkServer.sh status as a fallback
        if "${ZOOKEEPER_HOME}/bin/zkServer.sh" status /tmp/zoo.cfg 2>&1 | grep -q "Mode: standalone"; then
            log_info "ZooKeeper is ready (port=$ZOOKEEPER_PORT, mode=standalone)"
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

    # Add root qdisc with prio bands so we can attach netem per-IP
    tc qdisc add dev lo root handle 1: prio bands 16 priomap \
        0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 2>/dev/null || \
    tc qdisc replace dev lo root handle 1: prio bands 16 priomap \
        0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0

    # For each loopback IP (servers 2-5), add a netem delay.
    # Server 1 (127.0.0.1) has no extra delay — it's the "local" server
    # where the Jetpack leader and ZK leader both run.
    # Match both src and dst so that traffic *from* delayed IPs is also delayed.
    local band=1
    for ip in "${ips[@]:1}"; do
        tc qdisc add dev lo parent 1:$((band + 1)) handle $((10 + band)): \
            netem delay "${LATENCY_MS}ms" "${LATENCY_JITTER}ms" 2>/dev/null || \
        tc qdisc replace dev lo parent 1:$((band + 1)) handle $((10 + band)): \
            netem delay "${LATENCY_MS}ms" "${LATENCY_JITTER}ms"
        tc filter add dev lo parent 1:0 protocol ip prio "$band" u32 \
            match ip dst "$ip" flowid 1:$((band + 1)) 2>/dev/null || true
        tc filter add dev lo parent 1:0 protocol ip prio "$band" u32 \
            match ip src "$ip" flowid 1:$((band + 1)) 2>/dev/null || true
        log_info "  $ip: ${LATENCY_MS}ms +/- ${LATENCY_JITTER}ms delay"
        band=$((band + 1))
    done

    # ZooKeeper ZAB peer traffic workaround:
    # On Linux loopback, all ZK peer connections use 127.0.0.1 as both src
    # and dst (because ZK followers connect TO the leader at 127.0.0.1:2888
    # and the kernel picks 127.0.0.1 as source for loopback aliases).
    # The IP-based filters above don't catch this traffic.
    # Add port-based filters for the ZK leader's peer port (2888) to simulate
    # the replication RTT. This delays both directions of ZAB traffic:
    #   - dst port 2888: follower → leader (ACKs, connection setup)
    #   - src port 2888: leader → follower (proposals, commits)
    # Combined: 20ms each way = 40ms RTT, matching the intended WAN simulation.
    local zk_peer_port=2888
    tc qdisc add dev lo parent 1:$((band + 1)) handle $((10 + band)): \
        netem delay "${LATENCY_MS}ms" "${LATENCY_JITTER}ms" 2>/dev/null || \
    tc qdisc replace dev lo parent 1:$((band + 1)) handle $((10 + band)): \
        netem delay "${LATENCY_MS}ms" "${LATENCY_JITTER}ms"
    # Match traffic TO the ZK leader peer port (follower→leader direction)
    tc filter add dev lo parent 1:0 protocol ip prio "$band" u32 \
        match ip dport "$zk_peer_port" 0xffff flowid 1:$((band + 1)) 2>/dev/null || true
    # Match traffic FROM the ZK leader peer port (leader→follower direction)
    tc filter add dev lo parent 1:0 protocol ip prio "$band" u32 \
        match ip sport "$zk_peer_port" 0xffff flowid 1:$((band + 1)) 2>/dev/null || true
    log_info "  ZK peer port $zk_peer_port: ${LATENCY_MS}ms delay (ZAB replication)"

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

    # Assign myid in reverse order so that 127.0.0.1 (ENSEMBLE_IPS[0]) gets the
    # highest myid (3). ZooKeeper's Fast Leader Election picks the highest myid
    # when zxids are equal (as at fresh start), so this ensures the ZAB leader
    # is at 127.0.0.1 — the same host as the Jetpack leader. This avoids write
    # forwarding through tc/netem-delayed IPs.
    local myids=(3 2 1)

    for i in 0 1 2; do
        local ip="${ENSEMBLE_IPS[$i]}"
        local data_dir="/tmp/zk-ensemble-${i}"
        local client_port=$((base_client_port + i))
        local cfg="/tmp/zoo-${i}.cfg"
        local myid="${myids[$i]}"

        rm -rf "$data_dir"
        mkdir -p "$data_dir"
        echo "$myid" > "$data_dir/myid"
        ENSEMBLE_DATA_DIRS+=("$data_dir")

        # server.X lines use the myid as X, so server.3=127.0.0.1, server.2=127.0.0.2, etc.
        cat > "$cfg" <<EOF
tickTime=2000
initLimit=5
syncLimit=2
dataDir=$data_dir
clientPort=$client_port
admin.enableServer=false
4lw.commands.whitelist=ruok,srvr,stat,mntr
server.3=${ENSEMBLE_IPS[0]}:${base_peer_port}:${base_election_port}
server.2=${ENSEMBLE_IPS[1]}:$((base_peer_port + 1)):$((base_election_port + 1))
server.1=${ENSEMBLE_IPS[2]}:$((base_peer_port + 2)):$((base_election_port + 2))
EOF

        "${ZOOKEEPER_HOME}/bin/zkServer.sh" start "$cfg" > "/tmp/zk-ensemble-${i}.log" 2>&1
        local pid
        pid=$(cat "$data_dir/zookeeper_server.pid" 2>/dev/null || echo "")
        ENSEMBLE_PIDS+=("$pid")
        log_info "  Node myid=$myid: ip=$ip, port=$client_port, pid=$pid"
    done

    # Wait for ensemble to elect a leader
    log_info "Waiting for ZooKeeper ensemble to stabilize..."
    for attempt in $(seq 1 30); do
        local leaders=0
        local leader_ip=""
        for i in 0 1 2; do
            local port=$((base_client_port + i))
            local mode
            mode=$(echo srvr | nc -w 2 "${ENSEMBLE_IPS[$i]}" "$port" 2>/dev/null | grep "Mode:" | awk '{print $2}' || echo "")
            if [ "$mode" = "leader" ]; then
                leaders=$((leaders + 1))
                leader_ip="${ENSEMBLE_IPS[$i]}"
            fi
        done
        if [ "$leaders" -ge 1 ]; then
            log_info "ZooKeeper ensemble ready (leader at $leader_ip)"
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
    log_info "=== Single-Process Test: basic read/write through Jetpack + ZooKeeper ==="
    log_info "Config: 1 client, 3 server replicas, 1 partition, rw benchmark"
    log_info "Duration: ${TEST_DURATION}s"

    start_embedded_zookeeper

    mkdir -p "$LOG_DIR"

    local config_site="${JETPACK_DIR}/config/1c1s3r1p.yml"
    local config_mode="${JETPACK_DIR}/config/none_zookeeper.yml"
    local config_bench="${JETPACK_DIR}/config/rw_fixed.yml"
    local server_bin="${JETPACK_DIR}/build/deptran_server"

    if [ ! -x "$server_bin" ]; then
        log_error "Jetpack server binary not found at $server_bin"
        return 1
    fi

    for cfg in "$config_site" "$config_mode" "$config_bench"; do
        if [ ! -f "$cfg" ]; then
            log_error "Config file not found: $cfg"
            return 1
        fi
    done

    # Single-process mode: all servers + clients in one process.
    # The config 1c1s3r1p.yml maps all sites to process "localhost",
    # so -P localhost runs everything in one process.
    local pids=()
    local proc_names=("localhost")

    log_info "Starting Jetpack (all servers + client in one process)"
    "$server_bin" \
        -f "$config_site" \
        -f "$config_mode" \
        -f "$config_bench" \
        -f "${JETPACK_DIR}/config/client_closed.yml" \
        -f "${JETPACK_DIR}/config/concurrent_1.yml" \
        -P localhost \
        -d "$TEST_DURATION" \
        -r "$LOG_DIR" \
        > "$LOG_DIR/proc-localhost.log" 2>&1 &
    pids+=($!)

    log_info "Waiting for process to complete (timeout: $((TEST_DURATION + 30))s)..."

    local exit_code=0
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}" 2>/dev/null; then
            log_warn "Process ${proc_names[$i]} (PID ${pids[$i]}) exited with non-zero status"
            exit_code=1
        fi
    done

    # Validate results
    log_info "--- Result Validation ---"

    local throughput_found=false
    for proc in "${proc_names[@]}"; do
        local logfile="$LOG_DIR/proc-${proc}.log"
        if [ -f "$logfile" ]; then
            if grep -qi "throughput" "$logfile" 2>/dev/null; then
                throughput_found=true
                local tp_line
                tp_line=$(grep -i "Mid throughput" "$logfile" | tail -1)
                if [ -n "$tp_line" ]; then
                    log_info "  $proc: $tp_line"
                fi
            fi
            if grep -qi "segfault\|segmentation fault\|abort\|FATAL" "$logfile" 2>/dev/null; then
                log_error "  $proc: crash detected in log"
                exit_code=1
            fi
        fi
    done

    echo ""
    if [ $exit_code -eq 0 ]; then
        log_info "=== Single-Process Test PASSED ==="
        if $throughput_found; then
            log_info "  - Throughput metrics found in logs"
        fi
    else
        log_error "=== Single-Process Test FAILED ==="
    fi
    return "$exit_code"
}

run_multi_process_test() {
    log_info "=== Multi-Process Test: 5 servers + 5 clients with network latency ==="
    log_info "Config: 5 clients, 5 server replicas, 1 partition, rw benchmark"
    log_info "Latency: ${LATENCY_MS}ms +/- ${LATENCY_JITTER}ms between servers"
    log_info "Duration: ${TEST_DURATION}s"

    # Use 3-node ZK ensemble so writes include ZAB replication latency
    start_zookeeper_ensemble
    setup_latency

    mkdir -p "$LOG_DIR"

    local config_site="${JETPACK_DIR}/config/5c1s5r1p_zookeeper.yml"
    local config_mode="${JETPACK_DIR}/config/none_zookeeper.yml"
    local config_bench="${JETPACK_DIR}/config/rw_fixed.yml"
    local server_bin="${JETPACK_DIR}/build/deptran_server"

    if [ ! -x "$server_bin" ]; then
        log_error "Jetpack server binary not found at $server_bin"
        return 1
    fi

    for cfg in "$config_site" "$config_mode" "$config_bench"; do
        if [ ! -f "$cfg" ]; then
            log_error "Config file not found: $cfg"
            return 1
        fi
    done

    # Phase 1: Launch 5 processes (each hosts a server + client).
    # The -P flag takes the process name from the config's "process:" section,
    # NOT the site name. In 5c1s5r1p_zookeeper.yml: s101→h1, s201→h2, etc.
    local host_procs=("h1" "h2" "h3" "h4" "h5")
    local pids=()
    local proc_names=()

    for i in "${!host_procs[@]}"; do
        local proc="${host_procs[$i]}"
        log_info "Starting process $proc (server + client)"
        "$server_bin" \
            -f "$config_site" \
            -f "$config_mode" \
            -f "$config_bench" \
            -P "$proc" \
            -d "$TEST_DURATION" \
            -r "$LOG_DIR" \
            > "$LOG_DIR/proc-${proc}.log" 2>&1 &
        pids+=($!)
        proc_names+=("$proc")
    done

    log_info "Waiting for ${#pids[@]} processes to complete (timeout: $((TEST_DURATION + 60))s)..."

    # Wait for all processes
    local exit_code=0
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}" 2>/dev/null; then
            log_warn "Process ${proc_names[$i]} (PID ${pids[$i]}) exited with non-zero status"
            exit_code=1
        fi
    done

    remove_latency

    # Phase 2: Validate results
    log_info "--- Result Validation ---"

    local throughput_found=false
    for proc in "${proc_names[@]}"; do
        local logfile="$LOG_DIR/proc-${proc}.log"
        if [ -f "$logfile" ]; then
            if grep -qi "throughput" "$logfile" 2>/dev/null; then
                throughput_found=true
                local tp_line
                tp_line=$(grep -i "throughput" "$logfile" | tail -1)
                if [ -n "$tp_line" ]; then
                    log_info "  $proc: $tp_line"
                fi
            fi
            if grep -qi "segfault\|segmentation fault\|abort\|FATAL" "$logfile" 2>/dev/null; then
                log_error "  $proc: crash detected in log"
                exit_code=1
            fi
        else
            log_warn "  $proc: log file missing"
        fi
    done

    echo ""
    if [ $exit_code -eq 0 ]; then
        log_info "=== Multi-Process Test PASSED ==="
        if $throughput_found; then
            log_info "  - Throughput metrics found in logs"
        fi
    else
        log_error "=== Multi-Process Test FAILED ==="
        log_info "Check logs in $LOG_DIR for details"
    fi
    return "$exit_code"
}

run_recovery_test() {
    # RECOVERY_LATENCY_MS > 0: use 3-process WAN mode with tc/netem (RTT = 2×RECOVERY_LATENCY_MS).
    # RECOVERY_LATENCY_MS = 0 (default): single-process mode with 0ms RTT.
    local recovery_latency="${RECOVERY_LATENCY_MS:-0}"
    local recovery_jitter="${RECOVERY_LATENCY_JITTER:-0}"

    log_info "=== Failure Recovery Test: kill ZooKeeper leader, measure recovery ==="
    log_info "Config: 3 server replicas, 1 client, 3-node ZooKeeper ensemble"
    log_info "External kill: script kills ZooKeeper leader after 5s, measures recovery"
    log_info "Duration: ${TEST_DURATION}s"
    if [ "$recovery_latency" -gt 0 ] 2>/dev/null; then
        log_info "WAN mode: ${recovery_latency}ms one-way latency (RTT=$((recovery_latency * 2))ms)"
    fi

    start_zookeeper_ensemble

    mkdir -p "$LOG_DIR"
    local config
    if [ "$recovery_latency" -gt 0 ] 2>/dev/null; then
        config="${JETPACK_DIR}/config/1c1s3r1p_wan.yml"
    else
        config="${JETPACK_DIR}/config/1c1s3r1p.yml"
    fi
    local config_mode="${JETPACK_DIR}/config/none_zookeeper.yml"
    local config_bench="${JETPACK_DIR}/config/rw_fixed.yml"
    local binary="${JETPACK_DIR}/build/deptran_server"

    if [ ! -x "$binary" ]; then
        log_error "Jetpack server binary not found at $binary"
        return 1
    fi

    # Apply tc/netem latency before starting Jetpack (WAN mode only).
    # setup_latency reads LATENCY_MS/LATENCY_JITTER globals, so override them here.
    if [ "$recovery_latency" -gt 0 ] 2>/dev/null; then
        LATENCY_MS="$recovery_latency"
        LATENCY_JITTER="$recovery_jitter"
        setup_latency
    fi

    # Clean any stale signal files
    rm -f /tmp/JM_Jetpack_* 2>/dev/null || true

    # Get the current leader
    local leader
    leader=$(get_zookeeper_leader)
    local leader_ip="${leader%%:*}"
    log_info "Current ZooKeeper leader: $leader"

    # Start Jetpack WITHOUT failover config — external kill handles recovery.
    # JETPACK_ZOOKEEPER_RECOVERY is compiled in, so non-leader servers poll for
    # primary_elected signal and trigger JetpackRecoveryEntry() when found.
    local jetpack_pids=()
    if [ "$recovery_latency" -gt 0 ] 2>/dev/null; then
        log_info "Starting Jetpack (3-process WAN mode: h1=127.0.0.1, h2=127.0.0.2, h3=127.0.0.3)"
        # h1 runs the client (c01) and server (s101) — use normal TEST_DURATION.
        "$binary" \
            -f "$config" \
            -f "$config_mode" \
            -f "$config_bench" \
            -f "${JETPACK_DIR}/config/client_closed.yml" \
            -f "${JETPACK_DIR}/config/concurrent_1.yml" \
            -P h1 \
            -d "$TEST_DURATION" \
            -r "$LOG_DIR" \
            > "$LOG_DIR/proc-h1.log" 2>&1 &
        jetpack_pids+=($!)
        # h2 and h3 are server-only (no client). WaitForShutdown exits quickly
        # without a client, so use a 5× longer duration and kill them after recovery.
        local server_duration=$(( TEST_DURATION * 5 ))
        for proc in h2 h3; do
            "$binary" \
                -f "$config" \
                -f "$config_mode" \
                -f "$config_bench" \
                -f "${JETPACK_DIR}/config/client_closed.yml" \
                -f "${JETPACK_DIR}/config/concurrent_1.yml" \
                -P "$proc" \
                -d "$server_duration" \
                -r "$LOG_DIR" \
                > "$LOG_DIR/proc-${proc}.log" 2>&1 &
            jetpack_pids+=($!)
        done
    else
        log_info "Starting Jetpack (single-process, 0ms RTT)"
        "$binary" \
            -f "$config" \
            -f "$config_mode" \
            -f "$config_bench" \
            -f "${JETPACK_DIR}/config/client_closed.yml" \
            -f "${JETPACK_DIR}/config/concurrent_1.yml" \
            -P localhost \
            -d "$TEST_DURATION" \
            -r "$LOG_DIR" \
            > "$LOG_DIR/proc-localhost.log" 2>&1 &
        jetpack_pids+=($!)
    fi
    local jetpack_pid="${jetpack_pids[0]}"

    # Let Jetpack run for 5 seconds
    log_info "Letting Jetpack run for 5 seconds..."
    sleep 5

    # Kill the ZooKeeper leader
    local kill_ns
    kill_ns=$(date +%s%N)
    kill_zookeeper_node "$leader_ip"

    # Write failure_triggered signal so Jetpack clients pause
    echo "failure:failure_triggered" > /tmp/JM_Jetpack_failure_triggered
    log_info "Wrote failure_triggered signal"

    # Wait for new ZooKeeper leader
    local zk_downtime_ms="N/A"
    local new_leader_start_ns
    new_leader_start_ns=$(date +%s%N)
    if wait_zookeeper_new_leader "$leader_ip"; then
        local new_leader_ns
        new_leader_ns=$(date +%s%N)
        zk_downtime_ms=$(( (new_leader_ns - kill_ns) / 1000000 ))

        # Write primary_elected signal (AWS mode uses 0.0.0.0)
        echo "zookeeper:primary_elected" > /tmp/JM_Jetpack_0.0.0.0
        log_info "Wrote primary_elected signal to /tmp/JM_Jetpack_0.0.0.0"
        log_info "ZooKeeper downtime: ${zk_downtime_ms}ms"
    else
        log_error "No new ZooKeeper leader within timeout"
    fi

    # Wait for Jetpack recovery
    local jetpack_downtime_ms="N/A"
    local signal_write_ns
    signal_write_ns=$(date +%s%N)
    for attempt in $(seq 1 2000); do
        if [ -f /tmp/JM_Jetpack_recovery_finish_after_failure ] || \
           grep -rq "JETPACK-RECOVERY.*COMPLETED" "$LOG_DIR"/proc-*.log 2>/dev/null; then
            local recovery_ns
            recovery_ns=$(date +%s%N)
            jetpack_downtime_ms=$(( (recovery_ns - signal_write_ns) / 1000000 ))
            log_info "Jetpack recovery detected (${jetpack_downtime_ms}ms after signal)"
            break
        fi
        sleep 0.01
    done

    # In WAN mode: wait for h1 (client process) to finish, then kill server-only h2/h3.
    # In single-process mode: wait for the single process to finish.
    log_info "Waiting for Jetpack to finish..."
    local exit_code=0
    if [ "$recovery_latency" -gt 0 ] 2>/dev/null; then
        # Wait for h1 (client + server, index 0)
        if ! wait "${jetpack_pids[0]}" 2>/dev/null; then
            log_warn "Jetpack h1 process exited with non-zero status"
            exit_code=1
        fi
        # Kill server-only h2, h3
        for pid in "${jetpack_pids[@]:1}"; do
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        done
    else
        for pid in "${jetpack_pids[@]}"; do
            if ! wait "$pid" 2>/dev/null; then
                log_warn "A Jetpack process exited with non-zero status"
                exit_code=1
            fi
        done
    fi

    # Remove tc/netem latency rules (WAN mode only).
    if [ "$recovery_latency" -gt 0 ] 2>/dev/null; then
        remove_latency
    fi

    # Phase 2: Report results — check all proc-*.log files.
    log_info "--- Recovery Result Validation ---"

    if grep -rq "JETPACK-RECOVERY.*STARTING" "$LOG_DIR"/proc-*.log 2>/dev/null; then
        log_info "  Jetpack recovery started (found in logs)"
    fi
    if grep -rq "JETPACK-RECOVERY.*COMPLETED" "$LOG_DIR"/proc-*.log 2>/dev/null; then
        local dur
        dur=$(grep -roh "duration=[0-9]*ms" "$LOG_DIR"/proc-*.log 2>/dev/null | tail -1)
        log_info "  Jetpack recovery completed ${dur:+(}${dur}${dur:+)}"
    fi
    if grep -rq "ZOOKEEPER-FAILOVER\|primary_elected" "$LOG_DIR"/proc-*.log 2>/dev/null; then
        log_info "  ZooKeeper leader change detected in Jetpack logs"
    fi
    if grep -rqi "segfault\|segmentation fault\|abort\|FATAL" "$LOG_DIR"/proc-*.log 2>/dev/null; then
        log_error "  Crash detected in log"
        exit_code=1
    fi

    # Check surviving ZooKeeper nodes
    local surviving=0
    for i in 0 1 2; do
        local port=$((2181 + i))
        if echo ruok | nc -w 2 "${ENSEMBLE_IPS[$i]}" "$port" 2>/dev/null | grep -q imok; then
            surviving=$((surviving + 1))
        fi
    done
    log_info "  ZooKeeper ensemble: $surviving/3 nodes healthy"

    # Check signal files
    log_info "  Signal files:"
    ls -1 /tmp/JM_Jetpack_* 2>/dev/null | while read -r f; do
        log_info "    $(basename "$f"): $(head -1 "$f" 2>/dev/null)"
    done

    # Final verdict
    echo ""
    log_info "=== Recovery Timing ==="
    log_info "  Original protocol (ZooKeeper) downtime: ${zk_downtime_ms}ms"
    log_info "  Jetpack downtime: ${jetpack_downtime_ms}ms"

    if [ $exit_code -eq 0 ]; then
        log_info "=== Failure Recovery Test PASSED ==="
    else
        log_error "=== Failure Recovery Test FAILED ==="
    fi
    return "$exit_code"
}

# ---------------------------------------------------------------------------
# Configurable benchmark mode for performance chart experiments.
#
# Environment variables:
#   SITE_CONFIG       - Site config file name (default: 5c1s5r1p_zookeeper.yml)
#   MODE_CONFIG       - Mode config file name (default: none_zookeeper.yml)
#   CLIENT_CONFIG     - Client config file name (default: client_open.yml)
#   CONCURRENT_CONFIG - Concurrency config file name (default: concurrent_1.yml)
#   LATENCY_MS        - One-way latency in ms (default: 20)
#   LATENCY_JITTER    - Latency jitter in ms (default: 0)
#   TEST_DURATION     - Test duration in seconds (default: 30)
# ---------------------------------------------------------------------------
run_benchmark() {
    local site_config="${SITE_CONFIG:-5c1s5r1p_zookeeper.yml}"
    local mode_config="${MODE_CONFIG:-none_zookeeper.yml}"
    local client_config="${CLIENT_CONFIG:-client_open.yml}"
    local concurrent_config="${CONCURRENT_CONFIG:-concurrent_1.yml}"

    log_info "=== Benchmark Mode ==="
    log_info "Site config:       $site_config"
    log_info "Mode config:       $mode_config"
    log_info "Client config:     $client_config"
    log_info "Concurrent config: $concurrent_config"
    log_info "Latency:           ${LATENCY_MS}ms +/- ${LATENCY_JITTER}ms"
    log_info "Duration:          ${TEST_DURATION}s"

    # Use 3-node ZK ensemble so writes include ZAB replication latency
    # (majority ack required). tc/netem delays on 127.0.0.2-3 make ZAB
    # replication take ~40ms RTT, matching the simulated WAN.
    start_zookeeper_ensemble

    mkdir -p "$LOG_DIR"

    local config_site="${JETPACK_DIR}/config/${site_config}"
    local config_mode="${JETPACK_DIR}/config/${mode_config}"
    local config_bench="${JETPACK_DIR}/config/rw_fixed.yml"
    local config_client="${JETPACK_DIR}/config/${client_config}"
    local config_concurrent="${JETPACK_DIR}/config/${concurrent_config}"
    local server_bin="${JETPACK_DIR}/build/deptran_server"

    if [ ! -x "$server_bin" ]; then
        log_error "Jetpack server binary not found at $server_bin"
        return 1
    fi

    for cfg in "$config_site" "$config_mode" "$config_bench" "$config_client" "$config_concurrent"; do
        if [ ! -f "$cfg" ]; then
            log_error "Config file not found: $cfg"
            return 1
        fi
    done

    setup_latency "$LATENCY_MS" "$LATENCY_JITTER"

    local host_procs
    host_procs=($(grep -oP '^\s+h\d+' "$config_site" | sort -u | tr -d ' ' || echo "h1 h2 h3 h4 h5"))
    if [ ${#host_procs[@]} -eq 0 ]; then
        host_procs=("h1" "h2" "h3" "h4" "h5")
    fi

    local pids=()
    local proc_names=()

    for proc in "${host_procs[@]}"; do
        log_info "Starting process $proc"
        # shellcheck disable=SC2086
        "$server_bin" \
            -f "$config_site" \
            -f "$config_mode" \
            -f "$config_bench" \
            -f "$config_client" \
            -f "$config_concurrent" \
            -P "$proc" \
            -d "$TEST_DURATION" \
            -r "$LOG_DIR" \
            $SERVER_EXTRA_ARGS \
            > "$LOG_DIR/proc-${proc}.log" 2>&1 &
        pids+=($!)
        proc_names+=("$proc")
    done

    log_info "Waiting for ${#pids[@]} processes to complete (timeout: $((TEST_DURATION + 60))s)..."

    local exit_code=0
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}" 2>/dev/null; then
            log_warn "Process ${proc_names[$i]} (PID ${pids[$i]}) exited with non-zero status"
            exit_code=1
        fi
    done

    remove_latency

    log_info "--- Benchmark Results ---"
    for proc in "${proc_names[@]}"; do
        local logfile="$LOG_DIR/proc-${proc}.log"
        if [ -f "$logfile" ]; then
            # Print latency statistics (median, p90, p99, avg)
            local stats_line
            stats_line=$(grep "All-efficient-attempts.*statistics" "$logfile" 2>/dev/null | tail -1)
            if [ -n "$stats_line" ]; then
                log_info "  $proc: $stats_line"
            fi
            # Print latency distribution (percentiles)
            local dist_line
            dist_line=$(grep "All-efficient-attempts.*distribution" "$logfile" 2>/dev/null | tail -1)
            if [ -n "$dist_line" ]; then
                log_info "  $proc: $dist_line"
            fi
            # Print throughput
            local tp_line
            tp_line=$(grep "Mid throughput" "$logfile" 2>/dev/null | tail -1)
            if [ -n "$tp_line" ]; then
                log_info "  $proc: $tp_line"
            fi
            # Print fastpath statistics
            local fp_line
            fp_line=$(grep "Fastpath statistics" "$logfile" 2>/dev/null | tail -1)
            if [ -n "$fp_line" ]; then
                log_info "  $proc: $fp_line"
            fi
            # Print CPU usage (leader avg from client-observed responses)
            local cpu_line
            cpu_line=$(grep "Cpu-usage-leaders" "$logfile" 2>/dev/null | tail -1)
            if [ -n "$cpu_line" ]; then
                log_info "  $proc: $cpu_line"
            fi
            # Print queue depth (leader backend queue)
            local qd_line
            qd_line=$(grep "Queue-depth" "$logfile" 2>/dev/null | tail -1)
            if [ -n "$qd_line" ]; then
                log_info "  $proc: $qd_line"
            fi
        fi
    done

    if [ $exit_code -eq 0 ]; then
        log_info "=== Benchmark PASSED ==="
    else
        log_error "=== Benchmark FAILED ==="
    fi

    return $exit_code
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
    benchmark)
        run_benchmark
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
        log_error "Usage: $0 {single|multi|recovery|benchmark|zookeeper-only|bash}"
        exit 1
        ;;
esac
