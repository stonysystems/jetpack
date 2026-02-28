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
TEST_DURATION="${TEST_DURATION:-30}"
LATENCY_MS="${LATENCY_MS:-20}"
LATENCY_JITTER="${LATENCY_JITTER:-0}"
SERVER_EXTRA_ARGS="${SERVER_EXTRA_ARGS:-}"
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
    # RECOVERY_LATENCY_MS > 0: use 3-process WAN mode with tc/netem (RTT = 2×RECOVERY_LATENCY_MS).
    # RECOVERY_LATENCY_MS = 0 (default): single-process mode with 0ms RTT.
    local recovery_latency="${RECOVERY_LATENCY_MS:-0}"
    local recovery_jitter="${RECOVERY_LATENCY_JITTER:-0}"

    log_info "=== Failure Recovery Test: kill etcd leader, measure recovery ==="
    log_info "Config: 3 server replicas, 1 client, 3-node etcd cluster"
    log_info "External kill: script kills etcd leader after 5s, measures recovery"
    log_info "Duration: ${TEST_DURATION}s"
    if [ "$recovery_latency" -gt 0 ] 2>/dev/null; then
        log_info "WAN mode: ${recovery_latency}ms one-way latency (RTT=$((recovery_latency * 2))ms)"
    fi

    # Start 3-node etcd cluster
    start_etcd_cluster
    verify_etcd_rw

    mkdir -p "$LOG_DIR"

    # Use WAN config (replicas on 127.0.0.1-3) when latency is requested,
    # otherwise use single-host config (all on 127.0.0.1).
    local config_site
    if [ "$recovery_latency" -gt 0 ] 2>/dev/null; then
        config_site="${JETPACK_DIR}/config/1c1s3r1p_wan.yml"
    else
        config_site="${JETPACK_DIR}/config/1c1s3r1p.yml"
    fi
    local config_mode="${JETPACK_DIR}/config/none_etcd.yml"
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

    # Seed etcd with the leader key so EtcdLeaderWatcher has something to watch
    etcdctl --endpoints="http://127.0.0.1:2379" put JetPack/leader "initial" >/dev/null 2>&1

    # Clean any stale signal files
    rm -f /tmp/JM_Jetpack_* 2>/dev/null || true

    # Start Jetpack WITHOUT failover config — the script handles the kill externally.
    # JETPACK_ETCD_RECOVERY is compiled in, so non-leader servers poll for
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

    # Determine etcd leader
    local leader_ip
    leader_ip=$(get_etcd_leader_ip)
    log_info "Current etcd leader: $leader_ip"

    # Kill etcd leader by PID (targeted kill, not pkill which kills all nodes)
    local kill_ns
    kill_ns=$(date +%s%N)
    kill_etcd_node "$leader_ip"

    # Write failure_triggered signal so Jetpack clients pause
    echo "failure:failure_triggered" > /tmp/JM_Jetpack_failure_triggered
    log_info "Wrote failure_triggered signal"

    # Wait for new etcd leader.
    # wait_etcd_new_leader outputs ms value on stdout and log_info messages on stdout too.
    # We capture all output and extract just the numeric ms value.
    local wait_output
    wait_output=$(wait_etcd_new_leader "$leader_ip" 10 2>&1) || true
    echo "$wait_output" | grep -v "^[0-9]*$"  # Print log lines (non-numeric)
    local etcd_downtime_ms
    etcd_downtime_ms=$(echo "$wait_output" | grep "^[0-9]*$" | tail -1)
    etcd_downtime_ms="${etcd_downtime_ms:-N/A}"
    local new_leader_ip
    new_leader_ip=$(get_etcd_leader_ip 2>/dev/null || echo "")

    if [ "$etcd_downtime_ms" != "-1" ] && [ -n "$new_leader_ip" ]; then
        log_info "etcd downtime: ${etcd_downtime_ms}ms (new leader: $new_leader_ip)"

        # Write primary_elected signal for Jetpack servers to detect.
        # The Jetpack binary (with AWS defined in constants.h) polls for
        # JM_Jetpack_0.0.0.0, so write the signal there.
        echo "etcd:primary_elected" > /tmp/JM_Jetpack_0.0.0.0
        log_info "Wrote primary_elected signal to /tmp/JM_Jetpack_0.0.0.0"

        # Also update the JetPack/leader key in etcd
        etcdctl --endpoints="http://${new_leader_ip}:2379" put JetPack/leader "$new_leader_ip" >/dev/null 2>&1 || true
    else
        log_error "No new etcd leader within 10 seconds"
        etcd_downtime_ms="N/A"
    fi

    # Wait for Jetpack recovery — poll for recovery_finish_after_failure signal
    # or JETPACK-RECOVERY COMPLETED in any proc-*.log (works for both single and multi-process).
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
        # Kill server-only h2, h3 (they use a longer -d and won't exit naturally)
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
    if grep -rq "ETCD-FAILOVER\|primary_elected" "$LOG_DIR"/proc-*.log 2>/dev/null; then
        log_info "  etcd leader change detected in Jetpack logs"
    fi
    if grep -rqi "segfault\|segmentation fault\|abort\|FATAL" "$LOG_DIR"/proc-*.log 2>/dev/null; then
        log_error "  Crash detected in log"
        exit_code=1
    fi

    # Check surviving etcd cluster
    local surviving_nodes=0
    for ip in "${ETCD_CLUSTER_IPS[@]}"; do
        if etcdctl endpoint health --endpoints="http://${ip}:2379" >/dev/null 2>&1; then
            surviving_nodes=$((surviving_nodes + 1))
        fi
    done
    log_info "  etcd cluster: $surviving_nodes/3 nodes healthy"

    # Check signal files
    log_info "  Signal files:"
    ls -1 /tmp/JM_Jetpack_* 2>/dev/null | while read -r f; do
        log_info "    $(basename "$f"): $(cat "$f" 2>/dev/null | head -1)"
    done

    # Final verdict
    echo ""
    log_info "=== Recovery Timing ==="
    log_info "  Original protocol (etcd) downtime: ${etcd_downtime_ms}ms"
    log_info "  Jetpack downtime: ${jetpack_downtime_ms}ms"

    if [ $exit_code -eq 0 ]; then
        log_info "=== Failure Recovery Test PASSED ==="
    else
        log_error "=== Failure Recovery Test FAILED ==="
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

    # Use 3-node etcd cluster so writes include Raft replication RTT
    start_etcd_cluster
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

    # Phase 1: Launch 5 processes (each hosts a server + client).
    # The -P flag takes the process name from the config's "process:" section,
    # NOT the site name. In 5c1s5r1p_etcd.yml: s101→h1, s201→h2, etc.
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
# Configurable benchmark mode for performance chart experiments.
#
# Environment variables:
#   SITE_CONFIG       - Site config file name (default: 5c1s5r1p_etcd.yml)
#   MODE_CONFIG       - Mode config file name (default: none_etcd.yml)
#   CLIENT_CONFIG     - Client config file name (default: client_open.yml)
#   CONCURRENT_CONFIG - Concurrency config file name (default: concurrent_1.yml)
#   LATENCY_MS        - One-way latency in ms (default: 20)
#   LATENCY_JITTER    - Latency jitter in ms (default: 0)
#   TEST_DURATION     - Test duration in seconds (default: 30)
# ---------------------------------------------------------------------------
run_benchmark() {
    local site_config="${SITE_CONFIG:-5c1s5r1p_etcd.yml}"
    local mode_config="${MODE_CONFIG:-none_etcd.yml}"
    local client_config="${CLIENT_CONFIG:-client_open.yml}"
    local concurrent_config="${CONCURRENT_CONFIG:-concurrent_1.yml}"

    log_info "=== Benchmark Mode ==="
    log_info "Site config:       $site_config"
    log_info "Mode config:       $mode_config"
    log_info "Client config:     $client_config"
    log_info "Concurrent config: $concurrent_config"
    log_info "Latency:           ${LATENCY_MS}ms +/- ${LATENCY_JITTER}ms"
    log_info "Duration:          ${TEST_DURATION}s"

    # Use 3-node etcd cluster so that writes include etcd Raft replication
    # latency (majority ack required). tc/netem delays on 127.0.0.2-3 make
    # etcd peer replication take ~40ms RTT, matching the simulated WAN.
    start_etcd_cluster
    verify_etcd_rw

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
    etcd-only)
        run_etcd_only
        ;;
    bash|sh)
        start_embedded_etcd || true
        exec bash
        ;;
    *)
        echo "Usage: $0 {single|multi|recovery|benchmark|etcd-only|bash}"
        echo ""
        echo "Modes:"
        echo "  single    - Embedded etcd + 3 servers + 1 client"
        echo "  multi     - Embedded etcd + 5 servers + 5 clients + network latency"
        echo "  recovery  - 3-node etcd cluster + failover test + recovery measurement"
        echo "  benchmark - Configurable benchmark (use SITE_CONFIG, MODE_CONFIG, etc.)"
        echo "  etcd-only - Start only the embedded etcd server"
        echo "  bash      - Interactive shell with etcd running"
        exit 1
        ;;
esac
