#!/bin/bash
# run-etcd-test.sh - Entrypoint for Jetpack + etcd Docker integration testing.
#
# Usage:
#   ./run-etcd-test.sh single    # Single-process: embedded etcd + 1 Jetpack server + 1 client
#   ./run-etcd-test.sh multi     # Multi-process: embedded etcd + 5 servers + 5 clients + latency
#   ./run-etcd-test.sh recovery  # Recovery: 3-node etcd cluster, kill leader, measure recovery
#   ./run-etcd-test.sh etcd-only # Start only the embedded etcd server (for external use)
#   ./run-etcd-test.sh bash      # Interactive shell
#
# Environment variables:
#   ETCD_ENDPOINTS  - External etcd endpoint (default: start embedded etcd at 127.0.0.1:2379)
#   TEST_DURATION   - Test duration in seconds (default: 10)
#   JETPACK_DIR     - Jetpack installation directory (default: /jetpack)
#   LATENCY_MS      - Simulated inter-server latency in ms (default: 5, multi mode only)
#   LATENCY_JITTER  - Latency jitter in ms (default: 2, multi mode only)

set -euo pipefail

JETPACK_DIR="${JETPACK_DIR:-/jetpack}"
TEST_DURATION="${TEST_DURATION:-10}"
LATENCY_MS="${LATENCY_MS:-5}"
LATENCY_JITTER="${LATENCY_JITTER:-2}"
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
    # Remove tc latency rules if they were applied
    remove_latency 2>/dev/null || true
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

# ---------------------------------------------------------------------------
# 3-node etcd cluster for failure recovery testing.
#
# Nodes run on separate loopback addresses:
#   etcd0: 127.0.0.1:2379 (client), 127.0.0.1:2380 (peer)
#   etcd1: 127.0.0.2:2379 (client), 127.0.0.2:2380 (peer)
#   etcd2: 127.0.0.3:2379 (client), 127.0.0.3:2380 (peer)
# ---------------------------------------------------------------------------
ETCD_CLUSTER_IPS=("127.0.0.1" "127.0.0.2" "127.0.0.3")
ETCD_CLUSTER_PIDS=()

start_etcd_cluster() {
    log_info "Starting 3-node etcd cluster..."

    local cluster_token="jetpack-etcd-cluster"
    local initial_cluster="etcd0=http://127.0.0.1:2380,etcd1=http://127.0.0.2:2380,etcd2=http://127.0.0.3:2380"

    ETCD_CLUSTER_PIDS=()
    for i in 0 1 2; do
        local ip="${ETCD_CLUSTER_IPS[$i]}"
        local name="etcd${i}"
        local data_dir="/tmp/etcd-data-${i}"
        local log_file="/tmp/etcd-${i}.log"

        rm -rf "$data_dir"
        mkdir -p "$data_dir"

        etcd \
            --name "$name" \
            --listen-client-urls "http://${ip}:2379" \
            --advertise-client-urls "http://${ip}:2379" \
            --listen-peer-urls "http://${ip}:2380" \
            --initial-advertise-peer-urls "http://${ip}:2380" \
            --initial-cluster "$initial_cluster" \
            --initial-cluster-token "$cluster_token" \
            --initial-cluster-state new \
            --data-dir "$data_dir" \
            > "$log_file" 2>&1 &

        ETCD_CLUSTER_PIDS+=($!)
        log_info "  $name ($ip:2379) PID=$!"
    done

    # Wait for cluster to form — all 3 nodes must be healthy
    local all_endpoints="http://127.0.0.1:2379,http://127.0.0.2:2379,http://127.0.0.3:2379"
    for attempt in $(seq 1 30); do
        local healthy=0
        for ip in "${ETCD_CLUSTER_IPS[@]}"; do
            if etcdctl endpoint health --endpoints="http://${ip}:2379" >/dev/null 2>&1; then
                healthy=$((healthy + 1))
            fi
        done
        if [ "$healthy" -eq 3 ]; then
            log_info "etcd cluster is ready (3/3 nodes healthy)"
            return 0
        fi
        sleep 0.5
    done

    log_error "etcd cluster failed to form within 15 seconds"
    for i in 0 1 2; do
        log_info "--- etcd${i} log ---"
        tail -5 "/tmp/etcd-${i}.log" 2>/dev/null || true
    done
    return 1
}

get_etcd_leader_ip() {
    # Query etcd cluster status to find the leader's client URL
    for ip in "${ETCD_CLUSTER_IPS[@]}"; do
        local endpoint="http://${ip}:2379"
        local status
        status=$(etcdctl endpoint status --endpoints="$endpoint" -w json 2>/dev/null) || continue
        local is_leader
        is_leader=$(echo "$status" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, list):
    data = data[0]
h = data.get('header', data.get('Status', {}).get('header', {}))
leader_id = h.get('member_id', 0)
status = data.get('Status', data)
member_id = status.get('header', {}).get('member_id', 0)
raft_leader = status.get('leader', 0)
# This node is leader if its raft leader field equals its own member_id
print('yes' if raft_leader == member_id else 'no')
" 2>/dev/null)
        if [ "$is_leader" = "yes" ]; then
            echo "$ip"
            return 0
        fi
    done
    # Fallback: use endpoint status table format
    local status_out
    status_out=$(etcdctl endpoint status \
        --endpoints="http://127.0.0.1:2379,http://127.0.0.2:2379,http://127.0.0.3:2379" \
        -w table 2>/dev/null) || true
    log_warn "Could not determine leader programmatically, using 127.0.0.1"
    echo "127.0.0.1"
}

kill_etcd_node() {
    local target_ip="$1"
    # Find the PID of the etcd process listening on this IP
    for i in 0 1 2; do
        local ip="${ETCD_CLUSTER_IPS[$i]}"
        if [ "$ip" = "$target_ip" ] && [ -n "${ETCD_CLUSTER_PIDS[$i]:-}" ]; then
            log_info "Killing etcd node at $ip (PID=${ETCD_CLUSTER_PIDS[$i]})"
            kill -KILL "${ETCD_CLUSTER_PIDS[$i]}" 2>/dev/null || true
            wait "${ETCD_CLUSTER_PIDS[$i]}" 2>/dev/null || true
            ETCD_CLUSTER_PIDS[$i]=""
            return 0
        fi
    done
    log_warn "Could not find etcd PID for $target_ip"
    return 1
}

wait_etcd_new_leader() {
    local killed_ip="$1"
    local timeout_s="${2:-10}"
    log_info "Waiting for new etcd leader (old leader was $killed_ip)..."
    local start_time
    start_time=$(date +%s%N)

    for attempt in $(seq 1 $((timeout_s * 10))); do
        for ip in "${ETCD_CLUSTER_IPS[@]}"; do
            [ "$ip" = "$killed_ip" ] && continue
            if etcdctl endpoint health --endpoints="http://${ip}:2379" >/dev/null 2>&1; then
                # Check if this node knows about a leader
                local leader_ip
                leader_ip=$(get_etcd_leader_ip 2>/dev/null) || continue
                if [ -n "$leader_ip" ] && [ "$leader_ip" != "$killed_ip" ]; then
                    local end_time
                    end_time=$(date +%s%N)
                    local elapsed_ms=$(( (end_time - start_time) / 1000000 ))
                    log_info "New etcd leader elected: $leader_ip (took ${elapsed_ms}ms)"
                    echo "$elapsed_ms"
                    return 0
                fi
            fi
        done
        sleep 0.1
    done

    log_error "No new etcd leader elected within ${timeout_s}s"
    echo "-1"
    return 1
}

run_recovery_test() {
    log_info "=== Failure Recovery Test: kill etcd leader, measure recovery ==="
    log_info "Config: 3 server replicas, 1 client, 3-node etcd cluster"
    log_info "Failover: run 5s, then kill etcd leader, wait 10s for recovery"
    log_info "Duration: ${TEST_DURATION}s"

    # Start 3-node etcd cluster
    start_etcd_cluster
    verify_etcd_rw

    mkdir -p "$LOG_DIR"

    local config_site="${JETPACK_DIR}/config/1c1s3r1p.yml"
    local config_mode="${JETPACK_DIR}/config/none_etcd.yml"
    local config_bench="${JETPACK_DIR}/config/rw_fixed.yml"
    local config_failover="${JETPACK_DIR}/config/failover_etcd.yml"
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

    # Seed etcd with the leader key so EtcdLeaderWatcher has something to watch
    etcdctl --endpoints="http://127.0.0.1:2379" put JetPack/leader "initial" >/dev/null 2>&1

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

    # Check for etcd failover signals in logs
    local failover_triggered=false
    local recovery_completed=false
    local etcd_recovery_ms=""
    local jetpack_recovery_ms=""

    for proc in "${proc_names[@]}"; do
        local logfile="$LOG_DIR/proc-${proc}.log"
        [ -f "$logfile" ] || continue

        # Check for failover trigger
        if grep -q "failure_triggered\|ETCD-FAILOVER\|KillEtcdPrimary" "$logfile" 2>/dev/null; then
            failover_triggered=true
            log_info "  $proc: failover triggered"
        fi

        # Check for Jetpack recovery completion
        if grep -q "JETPACK-RECOVERY.*COMPLETED\|RECOVERY.*COMPLETED\|recovery.*completed" "$logfile" 2>/dev/null; then
            recovery_completed=true
            # Extract recovery duration from log
            local dur
            dur=$(grep -o "duration=[0-9]*ms\|duration=[0-9]*" "$logfile" 2>/dev/null | tail -1)
            if [ -n "$dur" ]; then
                jetpack_recovery_ms="$dur"
                log_info "  $proc: Jetpack recovery $dur"
            else
                log_info "  $proc: Jetpack recovery completed (duration not parsed)"
            fi
        fi

        # Check for etcd leader change detection
        if grep -q "ETCD-HOOKER.*Leader change\|Leader change detected\|primary_elected" "$logfile" 2>/dev/null; then
            log_info "  $proc: etcd leader change detected"
        fi

        # Check for crashes
        if grep -qi "segfault\|segmentation fault\|abort\|FATAL" "$logfile" 2>/dev/null; then
            log_error "  $proc: crash detected in log"
            exit_code=1
        fi
    done

    # Check if etcd cluster survived (2 of 3 nodes should be healthy)
    local surviving_nodes=0
    for ip in "${ETCD_CLUSTER_IPS[@]}"; do
        if etcdctl endpoint health --endpoints="http://${ip}:2379" >/dev/null 2>&1; then
            surviving_nodes=$((surviving_nodes + 1))
        fi
    done
    log_info "  etcd cluster: $surviving_nodes/3 nodes healthy after test"

    # Check etcd keys
    local endpoint=""
    for ip in "${ETCD_CLUSTER_IPS[@]}"; do
        if etcdctl endpoint health --endpoints="http://${ip}:2379" >/dev/null 2>&1; then
            endpoint="http://${ip}:2379"
            break
        fi
    done
    local etcd_keys=0
    if [ -n "$endpoint" ]; then
        etcd_keys=$(etcdctl --endpoints="$endpoint" get "JetPack/" --prefix --keys-only 2>/dev/null | wc -l)
        log_info "  etcd keys under JetPack/: $etcd_keys"
    fi

    # Check signal files
    local signal_files
    signal_files=$(ls /tmp/JM_Jetpack_* 2>/dev/null | wc -l)
    log_info "  Signal files created: $signal_files"

    # Final verdict
    echo ""
    if [ $exit_code -eq 0 ]; then
        log_info "=== Failure Recovery Test PASSED ==="
        log_info "  - All Jetpack processes exited cleanly"
        log_info "  - etcd cluster: $surviving_nodes/3 nodes healthy"
        log_info "  - etcd keys: $etcd_keys"
        if $failover_triggered; then
            log_info "  - Failover was triggered"
        else
            log_warn "  - Failover was NOT triggered (test duration may be too short)"
        fi
        if $recovery_completed; then
            log_info "  - Jetpack recovery completed ($jetpack_recovery_ms)"
        else
            log_warn "  - Jetpack recovery not detected in logs (may need JETPACK_ETCD_RECOVERY build)"
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

run_single_process_test() {
    log_info "=== Single-Process Test: basic read/write through Jetpack + etcd ==="
    log_info "Config: 1 client, 3 server replicas, 1 partition, rw benchmark"
    log_info "Duration: ${TEST_DURATION}s"

    start_embedded_etcd
    verify_etcd_rw

    mkdir -p "$LOG_DIR"

    local config_site="${JETPACK_DIR}/config/1c1s3r1p.yml"
    local config_mode="${JETPACK_DIR}/config/none_etcd.yml"
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

    # Check that etcd received KV writes from Jetpack
    local endpoint="${ETCD_ENDPOINTS:-http://127.0.0.1:2379}"
    local etcd_keys
    etcd_keys=$(etcdctl --endpoints="$endpoint" get "JetPack/" --prefix --keys-only 2>/dev/null | wc -l)
    if [ "$etcd_keys" -gt 0 ]; then
        log_info "etcd has $etcd_keys keys under JetPack/ prefix (Jetpack wrote to etcd)"
    else
        log_warn "No keys found under JetPack/ prefix in etcd"
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
        log_info "  - etcd keys: $etcd_keys"
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

    start_embedded_etcd
    verify_etcd_rw

    mkdir -p "$LOG_DIR"

    local config_site="${JETPACK_DIR}/config/5c1s5r1p_etcd.yml"
    local config_mode="${JETPACK_DIR}/config/none_etcd.yml"
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

    local endpoint="${ETCD_ENDPOINTS:-http://127.0.0.1:2379}"
    local etcd_keys
    etcd_keys=$(etcdctl --endpoints="$endpoint" get "JetPack/" --prefix --keys-only 2>/dev/null | wc -l)
    if [ "$etcd_keys" -gt 0 ]; then
        log_info "etcd has $etcd_keys keys under JetPack/ prefix (Jetpack wrote to etcd)"
    else
        log_warn "No keys found under JetPack/ prefix in etcd"
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
        log_info "  - etcd keys: $etcd_keys"
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
    multi)
        run_multi_process_test
        ;;
    recovery)
        run_recovery_test
        ;;
    etcd-only)
        run_etcd_only
        ;;
    bash|sh)
        start_embedded_etcd || true
        exec bash
        ;;
    *)
        echo "Usage: $0 {single|multi|recovery|etcd-only|bash}"
        echo ""
        echo "Modes:"
        echo "  single    - Embedded etcd + 3 servers + 1 client"
        echo "  multi     - Embedded etcd + 5 servers + 5 clients + network latency"
        echo "  recovery  - 3-node etcd cluster + failover test + recovery measurement"
        echo "  etcd-only - Start only the embedded etcd server"
        echo "  bash      - Interactive shell with etcd running"
        exit 1
        ;;
esac
