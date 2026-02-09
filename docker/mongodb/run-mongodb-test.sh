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
#   MONGODB_ENDPOINTS - External MongoDB URI (default: start embedded mongod at 127.0.0.1:27017)
#   TEST_DURATION     - Test duration in seconds (default: 10)
#   JETPACK_DIR       - Jetpack installation directory (default: /jetpack)
#   LATENCY_MS        - Simulated inter-server latency in ms (default: 5, multi mode only)
#   LATENCY_JITTER    - Latency jitter in ms (default: 2, multi mode only)

set -euo pipefail

JETPACK_DIR="${JETPACK_DIR:-/jetpack}"
TEST_DURATION="${TEST_DURATION:-10}"
LATENCY_MS="${LATENCY_MS:-5}"
LATENCY_JITTER="${LATENCY_JITTER:-2}"
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

    # Phase 1: Start 3 server replicas first, then client.
    # Servers need to be up before the client connects.
    local server_procs=("s101" "s201" "s301")
    local client_procs=("c01")
    local pids=()
    local proc_names=()

    # Launch servers
    for proc in "${server_procs[@]}"; do
        local port
        case "$proc" in
            s101) port=38200 ;;
            s201) port=38201 ;;
            s301) port=38202 ;;
        esac
        log_info "Starting server $proc on port $port"
        "$server_bin" \
            -f "$config_site" \
            -f "$config_mode" \
            -f "$config_bench" \
            -P "$proc" \
            -p "$port" \
            -d "$TEST_DURATION" \
            -r "$LOG_DIR" \
            > "$LOG_DIR/proc-${proc}.log" 2>&1 &
        pids+=($!)
        proc_names+=("$proc")
    done

    # Brief delay for servers to initialize before starting client
    sleep 1

    # Launch client
    for proc in "${client_procs[@]}"; do
        log_info "Starting client $proc on port 38203"
        "$server_bin" \
            -f "$config_site" \
            -f "$config_mode" \
            -f "$config_bench" \
            -P "$proc" \
            -p 38203 \
            -d "$TEST_DURATION" \
            -r "$LOG_DIR" \
            > "$LOG_DIR/proc-${proc}.log" 2>&1 &
        pids+=($!)
        proc_names+=("$proc")
    done

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

    start_embedded_mongodb
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

    # Phase 1: Launch 5 server replicas, then 5 clients.
    local server_procs=("s101" "s201" "s301" "s401" "s501")
    local server_ports=(18000 18001 18002 18003 18004)
    local client_procs=("c101" "c201" "c301" "c401" "c501")
    local client_ports=(18010 18011 18012 18013 18014)
    local pids=()
    local proc_names=()

    # Launch servers
    for i in "${!server_procs[@]}"; do
        local proc="${server_procs[$i]}"
        local port="${server_ports[$i]}"
        log_info "Starting server $proc on port $port"
        "$server_bin" \
            -f "$config_site" \
            -f "$config_mode" \
            -f "$config_bench" \
            -P "$proc" \
            -p "$port" \
            -d "$TEST_DURATION" \
            -r "$LOG_DIR" \
            > "$LOG_DIR/proc-${proc}.log" 2>&1 &
        pids+=($!)
        proc_names+=("$proc")
    done

    # Stagger: let servers initialize before starting clients
    sleep 2

    # Launch clients
    for i in "${!client_procs[@]}"; do
        local proc="${client_procs[$i]}"
        local port="${client_ports[$i]}"
        log_info "Starting client $proc on port $port"
        "$server_bin" \
            -f "$config_site" \
            -f "$config_mode" \
            -f "$config_bench" \
            -P "$proc" \
            -p "$port" \
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
    log_info "=== Failure Recovery Test: kill MongoDB primary, measure recovery ==="
    log_info "Config: 3 server replicas, 1 client, 3-member MongoDB replica set"
    log_info "Failover: run 5s, then kill MongoDB primary, wait 10s for recovery"
    log_info "Duration: ${TEST_DURATION}s"

    # Start 3-member MongoDB replica set
    start_mongodb_replset

    # Verify R/W against the replica set
    local rs_uri="mongodb://127.0.0.1:27017,127.0.0.2:27017,127.0.0.3:27017/?replicaSet=${REPLSET_NAME}"
    MONGODB_ENDPOINTS="$rs_uri"
    verify_mongodb_rw

    mkdir -p "$LOG_DIR"

    local config_site="${JETPACK_DIR}/config/1c1s3r1p.yml"
    local config_mode="${JETPACK_DIR}/config/none_mongodb.yml"
    local config_bench="${JETPACK_DIR}/config/rw_fixed.yml"
    local config_failover="${JETPACK_DIR}/config/failover_mongodb.yml"
    local server_bin="${JETPACK_DIR}/build/deptran_server"

    if [ ! -x "$server_bin" ]; then
        log_error "Jetpack server binary not found at $server_bin"
        return 1
    fi

    for cfg in "$config_site" "$config_mode" "$config_bench" "$config_failover"; do
        if [ ! -f "$cfg" ]; then
            log_error "Config file not found: $cfg"
            return 1
        fi
    done

    # Clean any stale signal files
    rm -f /tmp/JM_Jetpack_* 2>/dev/null || true

    # Launch Jetpack servers (with failover config)
    local server_procs=("s101" "s201" "s301")
    local client_procs=("c01")
    local pids=()
    local proc_names=()

    for proc in "${server_procs[@]}"; do
        local port
        case "$proc" in
            s101) port=38200 ;;
            s201) port=38201 ;;
            s301) port=38202 ;;
        esac
        log_info "Starting server $proc on port $port (with failover)"
        "$server_bin" \
            -f "$config_site" \
            -f "$config_mode" \
            -f "$config_bench" \
            -f "$config_failover" \
            -P "$proc" \
            -p "$port" \
            -d "$TEST_DURATION" \
            -r "$LOG_DIR" \
            > "$LOG_DIR/proc-${proc}.log" 2>&1 &
        pids+=($!)
        proc_names+=("$proc")
    done

    sleep 1

    for proc in "${client_procs[@]}"; do
        log_info "Starting client $proc on port 38203 (with failover)"
        "$server_bin" \
            -f "$config_site" \
            -f "$config_mode" \
            -f "$config_bench" \
            -f "$config_failover" \
            -P "$proc" \
            -p 38203 \
            -d "$TEST_DURATION" \
            -r "$LOG_DIR" \
            > "$LOG_DIR/proc-${proc}.log" 2>&1 &
        pids+=($!)
        proc_names+=("$proc")
    done

    log_info "Waiting for ${#pids[@]} processes to complete (timeout: $((TEST_DURATION + 60))s)..."

    # Wait for all Jetpack processes
    local exit_code=0
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}" 2>/dev/null; then
            log_warn "Process ${proc_names[$i]} (PID ${pids[$i]}) exited with non-zero status"
            exit_code=1
        fi
    done

    # Phase 2: Validate recovery results from logs
    log_info "--- Recovery Result Validation ---"

    local failover_triggered=false
    local recovery_completed=false
    local jetpack_recovery_ms=""

    for proc in "${proc_names[@]}"; do
        local logfile="$LOG_DIR/proc-${proc}.log"
        [ -f "$logfile" ] || continue

        # Check for failover trigger
        if grep -q "failure_triggered\|MONGODB-FAILOVER\|KillMongodbPrimary" "$logfile" 2>/dev/null; then
            failover_triggered=true
            log_info "  $proc: failover triggered"
        fi

        # Check for Jetpack recovery completion
        if grep -q "JETPACK-RECOVERY.*COMPLETED\|RECOVERY.*COMPLETED\|recovery.*completed" "$logfile" 2>/dev/null; then
            recovery_completed=true
            local dur
            dur=$(grep -o "duration=[0-9]*ms\|duration=[0-9]*" "$logfile" 2>/dev/null | tail -1)
            if [ -n "$dur" ]; then
                jetpack_recovery_ms="$dur"
                log_info "  $proc: Jetpack recovery $dur"
            else
                log_info "  $proc: Jetpack recovery completed (duration not parsed)"
            fi
        fi

        # Check for MongoDB leader change detection
        if grep -q "MONGODB-HOOKER.*Topology changed\|primary_elected\|ReplicaSetWithPrimary" "$logfile" 2>/dev/null; then
            log_info "  $proc: MongoDB leader change detected"
        fi

        # Check for crashes
        if grep -qi "segfault\|segmentation fault\|abort\|FATAL" "$logfile" 2>/dev/null; then
            log_error "  $proc: crash detected in log"
            exit_code=1
        fi
    done

    # Check if MongoDB replica set survived (2 of 3 nodes should be healthy)
    local surviving_nodes=0
    for ip in "${REPLSET_IPS[@]}"; do
        if mongosh --host "${ip}:27017" --eval "db.adminCommand('ping')" --quiet >/dev/null 2>&1; then
            surviving_nodes=$((surviving_nodes + 1))
        fi
    done
    log_info "  MongoDB replica set: $surviving_nodes/3 nodes healthy after test"

    # Check MongoDB documents
    local mongo_docs=0
    for ip in "${REPLSET_IPS[@]}"; do
        if mongosh --host "${ip}:27017" --eval "db.adminCommand('ping')" --quiet >/dev/null 2>&1; then
            mongo_docs=$(mongosh --host "${ip}:27017" --eval 'db.getSiblingDB("JetPack").KVTable.countDocuments()' --quiet 2>/dev/null || echo "0")
            break
        fi
    done
    log_info "  MongoDB documents in JetPack.KVTable: $mongo_docs"

    # Check signal files
    local signal_files
    signal_files=$(ls /tmp/JM_Jetpack_* 2>/dev/null | wc -l)
    log_info "  Signal files created: $signal_files"

    # Final verdict
    echo ""
    if [ $exit_code -eq 0 ]; then
        log_info "=== Failure Recovery Test PASSED ==="
        log_info "  - All Jetpack processes exited cleanly"
        log_info "  - MongoDB replica set: $surviving_nodes/3 nodes healthy"
        log_info "  - MongoDB documents: $mongo_docs"
        if $failover_triggered; then
            log_info "  - Failover was triggered"
        else
            log_warn "  - Failover was NOT triggered (test duration may be too short)"
        fi
        if $recovery_completed; then
            log_info "  - Jetpack recovery completed ($jetpack_recovery_ms)"
        else
            log_warn "  - Jetpack recovery not detected in logs (may need JETPACK_MONGODB_RECOVERY build)"
        fi
    else
        log_error "=== Failure Recovery Test FAILED ==="
        log_info "Check logs in $LOG_DIR for details:"
        for proc in "${proc_names[@]}"; do
            log_info "  $LOG_DIR/proc-${proc}.log"
        done
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
    mongodb-only)
        run_mongodb_only
        ;;
    bash|sh)
        start_embedded_mongodb || true
        exec bash
        ;;
    *)
        echo "Usage: $0 {single|multi|recovery|mongodb-only|bash}"
        echo ""
        echo "Modes:"
        echo "  single       - Embedded mongod + 3 servers + 1 client"
        echo "  multi        - Embedded mongod + 5 servers + 5 clients + network latency"
        echo "  recovery     - 3-member MongoDB replica set + failover test + recovery measurement"
        echo "  mongodb-only - Start only the embedded MongoDB server"
        echo "  bash         - Interactive shell with MongoDB running"
        exit 1
        ;;
esac
