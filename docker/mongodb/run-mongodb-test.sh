#!/bin/bash
# run-mongodb-test.sh - Entrypoint for Jetpack + MongoDB Docker integration testing.
#
# Usage:
#   ./run-mongodb-test.sh single       # Single-process: embedded mongod + 3 Jetpack servers + 1 client
#   ./run-mongodb-test.sh multi        # Multi-process: embedded mongod + 5 servers + 5 clients + latency
#   ./run-mongodb-test.sh recovery     # Recovery: 3-node MongoDB replica set, kill primary, measure recovery
#   ./run-mongodb-test.sh mongodb-only # Start only the embedded MongoDB server (for external use)
#   ./run-mongodb-test.sh bash         # Interactive shell
#
# Environment variables:
#   MONGODB_ENDPOINTS    - External MongoDB URI (default: start embedded mongod at 127.0.0.1:27017)
#   TEST_DURATION        - Test duration in seconds (default: 10)
#   JETPACK_DIR          - Jetpack installation directory (default: /jetpack)
#   LATENCY_MS           - Simulated inter-server latency in ms (default: 5, multi mode only)
#   LATENCY_JITTER       - Latency jitter in ms (default: 2, multi mode only)
#   RECOVERY_LATENCY_MS  - One-way latency for recovery test WAN mode in ms (default: 0 = single-process)
#   RECOVERY_LATENCY_JITTER - Jitter for recovery test WAN mode in ms (default: 0)

set -euo pipefail

JETPACK_DIR="${JETPACK_DIR:-/jetpack}"
TEST_DURATION="${TEST_DURATION:-30}"
LATENCY_MS="${LATENCY_MS:-20}"
LATENCY_JITTER="${LATENCY_JITTER:-0}"
MONGODB_PORT="${MONGODB_PORT:-27017}"
MONGODB_DATA_DIR="/tmp/mongodb-data"
MONGODB_LOG="/tmp/mongod.log"
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
    # Kill embedded mongod if we started it
    pkill -f "mongod --port" 2>/dev/null || true
    # Remove tc latency rules if they were applied
    remove_latency 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT

start_embedded_mongodb() {
    if [ -n "${MONGODB_ENDPOINTS:-}" ]; then
        log_info "Using external MongoDB at $MONGODB_ENDPOINTS"
        return 0
    fi

    log_info "Starting embedded MongoDB server..."
    rm -rf "$MONGODB_DATA_DIR"
    mkdir -p "$MONGODB_DATA_DIR"

    # Start mongod as a standalone instance (no replica set for single mode).
    # For replica set testing, use start_mongodb_replset() instead.
    mongod \
        --port "$MONGODB_PORT" \
        --bind_ip 127.0.0.1 \
        --dbpath "$MONGODB_DATA_DIR" \
        --logpath "$MONGODB_LOG" \
        --fork \
        --quiet

    # Wait for MongoDB to be ready
    for i in $(seq 1 30); do
        if mongosh --host "127.0.0.1:${MONGODB_PORT}" --eval "db.adminCommand('ping')" --quiet >/dev/null 2>&1; then
            log_info "MongoDB is ready (port=$MONGODB_PORT)"
            return 0
        fi
        sleep 0.5
    done

    log_error "MongoDB failed to start within 15 seconds"
    cat "$MONGODB_LOG" 2>/dev/null || true
    return 1
}

verify_mongodb_rw() {
    local host="${MONGODB_ENDPOINTS:-mongodb://127.0.0.1:${MONGODB_PORT}}"
    log_info "Verifying MongoDB read/write at $host ..."

    # Write a test document
    if ! mongosh "$host" --eval 'db.jetpack_test.insertOne({hello: "world"})' --quiet >/dev/null 2>&1; then
        log_error "MongoDB write failed"
        return 1
    fi

    # Read it back
    local val
    val=$(mongosh "$host" --eval 'db.jetpack_test.findOne({hello: "world"}).hello' --quiet 2>/dev/null)
    if [ "$val" != "world" ]; then
        log_error "MongoDB read verification failed: expected 'world', got '$val'"
        return 1
    fi

    # Cleanup
    mongosh "$host" --eval 'db.jetpack_test.drop()' --quiet >/dev/null 2>&1

    log_info "MongoDB read/write verification passed"
    return 0
}

run_single_process_test() {
    log_info "=== Single-Process Test: basic read/write through Jetpack + MongoDB ==="
    log_info "Config: 1 client, 3 server replicas, 1 partition, rw benchmark"
    log_info "Duration: ${TEST_DURATION}s"

    start_embedded_mongodb
    verify_mongodb_rw

    mkdir -p "$LOG_DIR"

    local config_site="${JETPACK_DIR}/config/1c1s3r1p.yml"
    local config_mode="${JETPACK_DIR}/config/none_mongodb.yml"
    local config_bench="${JETPACK_DIR}/config/rw_fixed.yml"
    local server_bin="${JETPACK_DIR}/build/deptran_server"

    if [ ! -x "$server_bin" ]; then
        log_error "Jetpack server binary not found at $server_bin"
        log_warn "Build may have failed. Check build logs."
        return 1
    fi

    # Verify all config files exist
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


    log_info "Waiting for ${#pids[@]} processes to complete (timeout: $((TEST_DURATION + 30))s)..."

    # Wait for all processes with a timeout
    local exit_code=0
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}" 2>/dev/null; then
            log_warn "Process ${proc_names[$i]} (PID ${pids[$i]}) exited with non-zero status"
            exit_code=1
        fi
    done

    # Phase 2: Validate results
    log_info "--- Result Validation ---"

    # Check that MongoDB received KV writes from Jetpack
    local mongo_host="${MONGODB_ENDPOINTS:-mongodb://127.0.0.1:${MONGODB_PORT}}"
    local mongo_docs
    mongo_docs=$(mongosh "$mongo_host" --eval 'db.getSiblingDB("JetPack").KVTable.countDocuments()' --quiet 2>/dev/null || echo "0")
    if [ "$mongo_docs" -gt 0 ] 2>/dev/null; then
        log_info "MongoDB has $mongo_docs documents in JetPack.KVTable (Jetpack wrote to MongoDB)"
    else
        log_warn "No documents found in JetPack.KVTable collection"
    fi

    # Check server logs for throughput
    local throughput_found=false
    for proc in "${proc_names[@]}"; do
        local logfile="$LOG_DIR/proc-${proc}.log"
        if [ -f "$logfile" ]; then
            # Check for throughput line (indicates benchmark ran)
            if grep -qi "throughput\|tps\|commit" "$logfile" 2>/dev/null; then
                throughput_found=true
                local tp_line
                tp_line=$(grep -i "throughput" "$logfile" | tail -1)
                if [ -n "$tp_line" ]; then
                    log_info "  $proc: $tp_line"
                fi
            fi
            # Check for errors/crashes
            if grep -qi "segfault\|segmentation fault\|abort\|FATAL" "$logfile" 2>/dev/null; then
                log_error "  $proc: crash detected in log"
                exit_code=1
            fi
        else
            log_warn "  $proc: log file missing"
        fi
    done

    # Final verdict
    echo ""
    if [ $exit_code -eq 0 ]; then
        log_info "=== Single-Process Test PASSED ==="
        log_info "  - All 4 processes exited cleanly"
        log_info "  - MongoDB documents: $mongo_docs"
        if $throughput_found; then
            log_info "  - Throughput metrics found in logs"
        fi
    else
        log_error "=== Single-Process Test FAILED ==="
        log_info "Check logs in $LOG_DIR for details:"
        for proc in "${proc_names[@]}"; do
            log_info "  $LOG_DIR/proc-${proc}.log"
        done
    fi

    return $exit_code
}

# ---------------------------------------------------------------------------
# Network latency simulation via tc/netem on the loopback interface.
#
# Each server binds to a different loopback address (127.0.0.1 - 127.0.0.5).
# We add netem qdisc rules per-IP to simulate inter-server network delay.
# Requires: iproute2 (tc), and --privileged or NET_ADMIN capability.
# ---------------------------------------------------------------------------
MULTI_LOOPBACK_IPS=("127.0.0.1" "127.0.0.2" "127.0.0.3" "127.0.0.4" "127.0.0.5")

setup_latency() {
    local delay_ms="$1"
    local jitter_ms="$2"

    if ! command -v tc &>/dev/null; then
        log_warn "tc (iproute2) not found — skipping latency simulation"
        return 0
    fi

    log_info "Setting up network latency: ${delay_ms}ms +/- ${jitter_ms}ms on lo"

    # Add root qdisc with prio bands so we can attach netem per-IP
    tc qdisc add dev lo root handle 1: prio bands 16 priomap \
        0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 2>/dev/null || {
        log_warn "Failed to add root qdisc — latency simulation skipped"
        return 0
    }

    # For each loopback IP (servers 2-5), add a netem delay.
    # Server 1 (127.0.0.1) has no extra delay — it's the "local" server.
    local band=1
    for ip in "${MULTI_LOOPBACK_IPS[@]:1}"; do
        tc qdisc add dev lo parent 1:$((band + 1)) handle $((10 + band)): \
            netem delay "${delay_ms}ms" "${jitter_ms}ms" 2>/dev/null || {
            log_warn "Failed to add netem for $ip"
            continue
        }
        tc filter add dev lo parent 1:0 protocol ip prio "$band" u32 \
            match ip dst "$ip" flowid 1:$((band + 1)) 2>/dev/null || true
        tc filter add dev lo parent 1:0 protocol ip prio "$band" u32 \
            match ip src "$ip" flowid 1:$((band + 1)) 2>/dev/null || true
        log_info "  $ip: ${delay_ms}ms +/- ${jitter_ms}ms delay"
        band=$((band + 1))
    done

    log_info "Latency simulation active"
}

remove_latency() {
    tc qdisc del dev lo root 2>/dev/null || true
}

run_multi_process_test() {
    log_info "=== Multi-Process Test: 5 servers + 5 clients with network latency ==="
    log_info "Config: 5 clients, 5 server replicas, 1 partition, rw benchmark"
    log_info "Latency: ${LATENCY_MS}ms +/- ${LATENCY_JITTER}ms between servers"
    log_info "Duration: ${TEST_DURATION}s"

    # Use 3-node MongoDB replica set so writes include replication latency
    start_mongodb_replset
    mongosh --host "127.0.0.1:27017" --eval "
        db.adminCommand({ setDefaultRWConcern: 1, defaultWriteConcern: { w: 'majority' } })
    " --quiet >/dev/null 2>&1 || log_warn "Could not set default write concern"
    verify_mongodb_rw

    mkdir -p "$LOG_DIR"

    local config_site="${JETPACK_DIR}/config/5c1s5r1p_mongodb.yml"
    local config_mode="${JETPACK_DIR}/config/none_mongodb.yml"
    local config_bench="${JETPACK_DIR}/config/rw_fixed.yml"
    local server_bin="${JETPACK_DIR}/build/deptran_server"

    if [ ! -x "$server_bin" ]; then
        log_error "Jetpack server binary not found at $server_bin"
        log_warn "Build may have failed. Check build logs."
        return 1
    fi

    for cfg in "$config_site" "$config_mode" "$config_bench"; do
        if [ ! -f "$cfg" ]; then
            log_error "Config file not found: $cfg"
            return 1
        fi
    done

    # Set up simulated network latency between server IPs
    setup_latency "$LATENCY_MS" "$LATENCY_JITTER"

    # Phase 1: Launch 5 processes (each hosts a server + client).
    # The -P flag takes the process name from the config's "process:" section,
    # NOT the site name. In 5c1s5r1p_mongodb.yml: s101→h1, s201→h2, etc.
    local host_procs=("h1" "h2" "h3" "h4" "h5")
    local pids=()
    local proc_names=()

    # Launch each process (server + client co-located)
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

    # Remove latency rules now that test is done
    remove_latency

    # Phase 2: Validate results
    log_info "--- Result Validation ---"

    local mongo_host="${MONGODB_ENDPOINTS:-mongodb://127.0.0.1:${MONGODB_PORT}}"
    local mongo_docs
    mongo_docs=$(mongosh "$mongo_host" --eval 'db.getSiblingDB("JetPack").KVTable.countDocuments()' --quiet 2>/dev/null || echo "0")
    if [ "$mongo_docs" -gt 0 ] 2>/dev/null; then
        log_info "MongoDB has $mongo_docs documents in JetPack.KVTable (Jetpack wrote to MongoDB)"
    else
        log_warn "No documents found in JetPack.KVTable collection"
    fi

    local throughput_found=false
    local crash_found=false
    for proc in "${proc_names[@]}"; do
        local logfile="$LOG_DIR/proc-${proc}.log"
        if [ -f "$logfile" ]; then
            if grep -qi "throughput\|tps\|commit" "$logfile" 2>/dev/null; then
                throughput_found=true
                local tp_line
                tp_line=$(grep -i "throughput" "$logfile" | tail -1)
                if [ -n "$tp_line" ]; then
                    log_info "  $proc: $tp_line"
                fi
            fi
            if grep -qi "segfault\|segmentation fault\|abort\|FATAL" "$logfile" 2>/dev/null; then
                log_error "  $proc: crash detected in log"
                crash_found=true
                exit_code=1
            fi
        else
            log_warn "  $proc: log file missing"
        fi
    done

    # Final verdict
    echo ""
    if [ $exit_code -eq 0 ]; then
        log_info "=== Multi-Process Test PASSED ==="
        log_info "  - All 10 processes (5 servers + 5 clients) exited cleanly"
        log_info "  - MongoDB documents: $mongo_docs"
        log_info "  - Latency: ${LATENCY_MS}ms +/- ${LATENCY_JITTER}ms"
        if $throughput_found; then
            log_info "  - Throughput metrics found in logs"
        fi
    else
        log_error "=== Multi-Process Test FAILED ==="
        log_info "Check logs in $LOG_DIR for details:"
        for proc in "${proc_names[@]}"; do
            log_info "  $LOG_DIR/proc-${proc}.log"
        done
    fi

    return $exit_code
}

# ---------------------------------------------------------------------------
# 3-member MongoDB replica set for failure recovery testing.
#
# Members run on separate loopback addresses:
#   mongod0: 127.0.0.1:27017 (data), log: /tmp/mongod-0.log
#   mongod1: 127.0.0.2:27017 (data), log: /tmp/mongod-1.log
#   mongod2: 127.0.0.3:27017 (data), log: /tmp/mongod-2.log
# ---------------------------------------------------------------------------
REPLSET_IPS=("127.0.0.1" "127.0.0.2" "127.0.0.3")
REPLSET_PIDS=()
REPLSET_NAME="jetpack-rs"

start_mongodb_replset() {
    log_info "Starting 3-member MongoDB replica set..."

    REPLSET_PIDS=()
    for i in 0 1 2; do
        local ip="${REPLSET_IPS[$i]}"
        local data_dir="/tmp/mongodb-data-${i}"
        local log_file="/tmp/mongod-${i}.log"

        rm -rf "$data_dir"
        mkdir -p "$data_dir"

        mongod \
            --replSet "$REPLSET_NAME" \
            --port 27017 \
            --bind_ip "$ip" \
            --dbpath "$data_dir" \
            --logpath "$log_file" \
            --fork \
            --quiet

        # Get the PID of the forked mongod
        local pid
        pid=$(pgrep -f "mongod.*--bind_ip ${ip}" | tail -1)
        REPLSET_PIDS+=("$pid")
        log_info "  mongod${i} ($ip:27017) PID=$pid"
    done

    # Wait for all mongod instances to be reachable
    for i in 0 1 2; do
        local ip="${REPLSET_IPS[$i]}"
        for attempt in $(seq 1 30); do
            if mongosh --host "${ip}:27017" --eval "db.adminCommand('ping')" --quiet >/dev/null 2>&1; then
                break
            fi
            sleep 0.5
        done
    done

    # Initiate the replica set
    log_info "Initiating replica set '$REPLSET_NAME'..."
    mongosh --host "127.0.0.1:27017" --eval "
        rs.initiate({
            _id: '$REPLSET_NAME',
            members: [
                { _id: 0, host: '127.0.0.1:27017' },
                { _id: 1, host: '127.0.0.2:27017' },
                { _id: 2, host: '127.0.0.3:27017' }
            ]
        })
    " --quiet >/dev/null 2>&1

    # Wait for replica set to elect a primary
    for attempt in $(seq 1 60); do
        local primary
        primary=$(get_mongodb_primary 2>/dev/null) || true
        if [ -n "$primary" ]; then
            log_info "Replica set is ready (primary=$primary)"
            return 0
        fi
        sleep 0.5
    done

    log_error "MongoDB replica set failed to elect a primary within 30 seconds"
    for i in 0 1 2; do
        log_info "--- mongod${i} log ---"
        tail -5 "/tmp/mongod-${i}.log" 2>/dev/null || true
    done
    return 1
}

get_mongodb_primary() {
    # Query any replica set member to find the current primary
    for ip in "${REPLSET_IPS[@]}"; do
        local result
        result=$(mongosh --host "${ip}:27017" --eval '
            var s = rs.status();
            var primary = "";
            s.members.forEach(function(m) {
                if (m.stateStr === "PRIMARY") primary = m.name;
            });
            print(primary);
        ' --quiet 2>/dev/null) || continue
        if [ -n "$result" ] && [ "$result" != "" ]; then
            # Extract IP from host:port
            echo "$result" | cut -d: -f1
            return 0
        fi
    done
    return 1
}

kill_mongodb_node() {
    local target_ip="$1"
    for i in 0 1 2; do
        local ip="${REPLSET_IPS[$i]}"
        if [ "$ip" = "$target_ip" ] && [ -n "${REPLSET_PIDS[$i]:-}" ]; then
            log_info "Killing MongoDB node at $ip (PID=${REPLSET_PIDS[$i]})"
            kill -KILL "${REPLSET_PIDS[$i]}" 2>/dev/null || true
            wait "${REPLSET_PIDS[$i]}" 2>/dev/null || true
            REPLSET_PIDS[$i]=""
            return 0
        fi
    done
    log_warn "Could not find mongod PID for $target_ip"
    return 1
}

wait_mongodb_new_primary() {
    local killed_ip="$1"
    local timeout_s="${2:-30}"
    log_info "Waiting for new MongoDB primary (old primary was $killed_ip)..."
    local start_time
    start_time=$(date +%s%N)

    for attempt in $(seq 1 $((timeout_s * 10))); do
        local primary
        primary=$(get_mongodb_primary 2>/dev/null) || true
        if [ -n "$primary" ] && [ "$primary" != "$killed_ip" ]; then
            local end_time
            end_time=$(date +%s%N)
            local elapsed_ms=$(( (end_time - start_time) / 1000000 ))
            log_info "New MongoDB primary elected: $primary (took ${elapsed_ms}ms)"
            echo "$elapsed_ms"
            return 0
        fi
        sleep 0.1
    done

    log_error "No new MongoDB primary elected within ${timeout_s}s"
    echo "-1"
    return 1
}

run_recovery_test() {
    # RECOVERY_LATENCY_MS > 0: use 3-process WAN mode with tc/netem (RTT = 2×RECOVERY_LATENCY_MS).
    # RECOVERY_LATENCY_MS = 0 (default): single-process mode with 0ms RTT.
    local recovery_latency="${RECOVERY_LATENCY_MS:-0}"
    local recovery_jitter="${RECOVERY_LATENCY_JITTER:-0}"

    log_info "=== Failure Recovery Test: kill MongoDB primary, measure recovery ==="
    log_info "Config: 3 server replicas, 1 client, 3-member MongoDB replica set"
    log_info "External kill: script kills MongoDB primary after 5s, measures recovery"
    log_info "Duration: ${TEST_DURATION}s"
    if [ "$recovery_latency" -gt 0 ] 2>/dev/null; then
        log_info "WAN mode: ${recovery_latency}ms one-way latency (RTT=$((recovery_latency * 2))ms)"
    fi

    # Start 3-member MongoDB replica set
    start_mongodb_replset

    # Verify R/W against the replica set
    local rs_uri="mongodb://127.0.0.1:27017,127.0.0.2:27017,127.0.0.3:27017/?replicaSet=${REPLSET_NAME}"
    MONGODB_ENDPOINTS="$rs_uri"
    verify_mongodb_rw

    mkdir -p "$LOG_DIR"

    local config_site
    if [ "$recovery_latency" -gt 0 ] 2>/dev/null; then
        config_site="${JETPACK_DIR}/config/1c1s3r1p_wan.yml"
    else
        config_site="${JETPACK_DIR}/config/1c1s3r1p.yml"
    fi
    local config_mode="${JETPACK_DIR}/config/none_mongodb.yml"
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

    # Apply tc/netem latency before starting Jetpack (WAN mode only).
    if [ "$recovery_latency" -gt 0 ] 2>/dev/null; then
        setup_latency "$recovery_latency" "$recovery_jitter"
    fi

    # Clean any stale signal files
    rm -f /tmp/JM_Jetpack_* 2>/dev/null || true

    # Start Jetpack WITHOUT failover config — the script handles the kill externally.
    # JETPACK_MONGODB_RECOVERY is compiled in, so non-leader servers poll for
    # primary_elected signal and trigger JetpackRecoveryEntry() when found.
    local jetpack_pids=()
    if [ "$recovery_latency" -gt 0 ] 2>/dev/null; then
        log_info "Starting Jetpack (3-process WAN mode: h1=127.0.0.1, h2=127.0.0.2, h3=127.0.0.3)"
        # h1 runs the client (c01) and server (s101) — use normal TEST_DURATION.
        "$server_bin" \
            -f "$config_site" \
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
            "$server_bin" \
                -f "$config_site" \
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
        jetpack_pids+=($!)
    fi
    local jetpack_pid="${jetpack_pids[0]}"

    # Let Jetpack run normally for 5 seconds
    log_info "Letting Jetpack run for 5 seconds..."
    sleep 5

    # Determine MongoDB primary
    local primary_ip
    primary_ip=$(get_mongodb_primary)
    log_info "Current MongoDB primary: $primary_ip"

    # Kill MongoDB primary by PID
    local kill_ns
    kill_ns=$(date +%s%N)
    kill_mongodb_node "$primary_ip"

    # Write failure_triggered signal so Jetpack clients pause
    echo "failure:failure_triggered" > /tmp/JM_Jetpack_failure_triggered
    log_info "Wrote failure_triggered signal"

    # Wait for new MongoDB primary
    local wait_output
    wait_output=$(wait_mongodb_new_primary "$primary_ip" 30 2>&1) || true
    echo "$wait_output" | grep -v "^[0-9]*$" | grep -v "^-1$"
    local mongodb_downtime_ms
    mongodb_downtime_ms=$(echo "$wait_output" | grep "^[0-9]*$" | tail -1)
    mongodb_downtime_ms="${mongodb_downtime_ms:-N/A}"
    local new_primary_ip
    new_primary_ip=$(get_mongodb_primary 2>/dev/null || echo "")

    if [ "$mongodb_downtime_ms" != "N/A" ] && [ -n "$new_primary_ip" ]; then
        log_info "MongoDB downtime: ${mongodb_downtime_ms}ms (new primary: $new_primary_ip)"

        # Write primary_elected signal (AWS mode uses 0.0.0.0)
        echo "mongo:primary_elected" > /tmp/JM_Jetpack_0.0.0.0
        log_info "Wrote primary_elected signal to /tmp/JM_Jetpack_0.0.0.0"
    else
        log_error "No new MongoDB primary within 30 seconds"
        mongodb_downtime_ms="N/A"
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
    if grep -rq "MONGODB-FAILOVER\|primary_elected" "$LOG_DIR"/proc-*.log 2>/dev/null; then
        log_info "  MongoDB primary change detected in Jetpack logs"
    fi
    if grep -rqi "segfault\|segmentation fault\|abort\|FATAL" "$LOG_DIR"/proc-*.log 2>/dev/null; then
        log_error "  Crash detected in log"
        exit_code=1
    fi

    # Check surviving MongoDB nodes
    local surviving_nodes=0
    for ip in "${REPLSET_IPS[@]}"; do
        if mongosh --host "${ip}:27017" --eval "db.adminCommand('ping')" --quiet >/dev/null 2>&1; then
            surviving_nodes=$((surviving_nodes + 1))
        fi
    done
    log_info "  MongoDB replica set: $surviving_nodes/3 nodes healthy"

    # Check signal files
    log_info "  Signal files:"
    ls -1 /tmp/JM_Jetpack_* 2>/dev/null | while read -r f; do
        log_info "    $(basename "$f"): $(head -1 "$f" 2>/dev/null)"
    done

    # Final verdict
    echo ""
    log_info "=== Recovery Timing ==="
    log_info "  Original protocol (MongoDB) downtime: ${mongodb_downtime_ms}ms"
    log_info "  Jetpack downtime: ${jetpack_downtime_ms}ms"

    if [ $exit_code -eq 0 ]; then
        log_info "=== Failure Recovery Test PASSED ==="
    else
        log_error "=== Failure Recovery Test FAILED ==="
    fi

    return $exit_code
}

run_mongodb_only() {
    log_info "=== Starting MongoDB server only ==="
    start_embedded_mongodb
    verify_mongodb_rw
    log_info "MongoDB is running at 127.0.0.1:${MONGODB_PORT}"
    log_info "Press Ctrl+C to stop"
    wait
}

# ---------------------------------------------------------------------------
# Configurable benchmark mode for performance chart experiments.
#
# Environment variables:
#   SITE_CONFIG       - Site config file name (default: 5c1s5r1p_mongodb.yml)
#   MODE_CONFIG       - Mode config file name (default: none_mongodb.yml)
#   CLIENT_CONFIG     - Client config file name (default: client_open.yml)
#   CONCURRENT_CONFIG - Concurrency config file name (default: concurrent_1.yml)
#   LATENCY_MS        - One-way latency in ms (default: 20)
#   LATENCY_JITTER    - Latency jitter in ms (default: 0)
#   TEST_DURATION     - Test duration in seconds (default: 30)
#
# Example:
#   SITE_CONFIG=1c1s5r5p.yml MODE_CONFIG=none_mongodb.yml CLIENT_CONFIG=client_open.yml \
#   CONCURRENT_CONFIG=concurrent_1.yml LATENCY_MS=20 LATENCY_JITTER=0 TEST_DURATION=30 \
#   ./run-mongodb-test.sh benchmark
# ---------------------------------------------------------------------------
run_benchmark() {
    local site_config="${SITE_CONFIG:-5c1s5r1p_mongodb.yml}"
    local mode_config="${MODE_CONFIG:-none_mongodb.yml}"
    local client_config="${CLIENT_CONFIG:-client_open.yml}"
    local concurrent_config="${CONCURRENT_CONFIG:-concurrent_1.yml}"

    log_info "=== Benchmark Mode ==="
    log_info "Site config:       $site_config"
    log_info "Mode config:       $mode_config"
    log_info "Client config:     $client_config"
    log_info "Concurrent config: $concurrent_config"
    log_info "Latency:           ${LATENCY_MS}ms +/- ${LATENCY_JITTER}ms"
    log_info "Duration:          ${TEST_DURATION}s"

    # Use 3-node MongoDB replica set so writes include replication latency.
    # Set w:majority so writes wait for majority ack (matching etcd/ZK behavior).
    # tc/netem delays on 127.0.0.2-3 make replication take ~40ms RTT.
    start_mongodb_replset
    # Set default write concern to majority so update_one waits for replication
    mongosh --host "127.0.0.1:27017" --eval "
        db.adminCommand({ setDefaultRWConcern: 1, defaultWriteConcern: { w: 'majority' } })
    " --quiet >/dev/null 2>&1 || log_warn "Could not set default write concern"
    verify_mongodb_rw

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

    # Set up simulated network latency between server IPs
    setup_latency "$LATENCY_MS" "$LATENCY_JITTER"

    # Discover which processes are defined in the site config
    local host_procs
    host_procs=($(grep -oP '^\s+h\d+' "$config_site" | sort -u | tr -d ' ' || echo "h1 h2 h3 h4 h5"))
    if [ ${#host_procs[@]} -eq 0 ]; then
        host_procs=("h1" "h2" "h3" "h4" "h5")
    fi

    local pids=()
    local proc_names=()

    for proc in "${host_procs[@]}"; do
        log_info "Starting process $proc"
        "$server_bin" \
            -f "$config_site" \
            -f "$config_mode" \
            -f "$config_bench" \
            -f "$config_client" \
            -f "$config_concurrent" \
            -P "$proc" \
            -d "$TEST_DURATION" \
            -r "$LOG_DIR" \
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

    # Print results
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
        fi
    done

    if [ $exit_code -eq 0 ]; then
        log_info "=== Benchmark PASSED ==="
    else
        log_error "=== Benchmark FAILED ==="
    fi

    return $exit_code
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
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
    mongodb-only)
        run_mongodb_only
        ;;
    bash|sh)
        start_embedded_mongodb || true
        exec bash
        ;;
    *)
        echo "Usage: $0 {single|multi|recovery|benchmark|mongodb-only|bash}"
        echo ""
        echo "Modes:"
        echo "  single       - Embedded mongod + 3 servers + 1 client"
        echo "  multi        - Embedded mongod + 5 servers + 5 clients + network latency"
        echo "  recovery     - 3-member MongoDB replica set + failover test + recovery measurement"
        echo "  benchmark    - Configurable benchmark (use SITE_CONFIG, MODE_CONFIG, etc.)"
        echo "  mongodb-only - Start only the embedded MongoDB server"
        echo "  bash         - Interactive shell with MongoDB running"
        exit 1
        ;;
esac
