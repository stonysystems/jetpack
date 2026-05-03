#!/bin/bash
# run_single_exp.sh — Run a single experiment point with /proc/stat CPU monitoring.
#
# Usage: ./run_single_exp.sh <protocol_cfg> <mode> <concurrent_cfg> <label> <result_dir> [<client_cfg>]
# Example: ./run_single_exp.sh none_raft.yml 0 concurrent_1.yml raft-c1 results/2026-04-14-raft-jetpack-swiftpaxos-style
#          ./run_single_exp.sh none_raft.yml 0 concurrent_500.yml raft-N60c500 results/bisection 60c1s5r5p-zoo.yml

set -euo pipefail

PROTOCOL_CFG="$1"    # e.g. none_raft.yml
MODE="$2"            # e.g. 0, 100, 101
CONC_CFG="$3"        # e.g. concurrent_1.yml
LABEL="$4"           # e.g. raft-c1
RESULT_DIR="$5"      # e.g. results/2026-04-14-raft-jetpack-swiftpaxos-style
CLIENT_CFG="${6:-30c1s5r5p-zoo.yml}"  # e.g. 60c1s5r5p-zoo.yml (default: 30 clients)
WORKLOAD_CFG="${7:-rw_1000000.yml}"   # e.g. rw_readonly_1000000.yml (default: 1M-key uniform read+write)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Read setup.json
SERVER_USERNAME=$(jq -r '.server_username' "$SCRIPT_DIR/setup.json")
N_SERVER=$(jq -r '.n_server' "$SCRIPT_DIR/setup.json")
ZOO_DIR=$(jq -r '.zoo_directory' "$SCRIPT_DIR/setup.json")

declare -a servers replicanames
for i in $(seq 0 $((N_SERVER - 1))); do
    ip=$(jq -r ".servers[$i].server_${i}_ip" "$SCRIPT_DIR/setup.json")
    servers+=("$ip")
    # Human-facing names are zoo1..zoo5 (1-indexed to match .101..105).
    # Internally locale_id is still 0..4; the name is only a display string.
    replicanames+=("zoo$((i+1))")
done

DURATION=30
TIMEOUT_SEC=180

# Server-thread pin core. Forwarded to deptran_server via SERVER_CORE_ID and
# used locally to pick the matching /proc/stat row for CPU parsing.
SERVER_CORE_ID="${SERVER_CORE_ID:-1}"
SERVER_CPU_ROW="cpu${SERVER_CORE_ID} "

mkdir -p "$RESULT_DIR"

# Kill leftover deptran_server processes
echo "[$LABEL] Cleaning up old processes..."
for ip in "${servers[@]}"; do
    ssh "$SERVER_USERNAME@$ip" "pkill -9 deptran_server 2>/dev/null; rm -f /tmp/JM_*" &>/dev/null &
done
wait
# Wait for OS-level TIME_WAIT on server ports to clear so the next run doesn't
# hit "cannot bind to: 0.0.0.0:38000". Linux by default holds sockets in
# TIME_WAIT for ~60s, but SO_REUSEADDR + short pause is typically enough.
sleep 6

# Clean recent_csv
ssh "$SERVER_USERNAME@${servers[0]}" "mkdir -p $ZOO_DIR/results/recent_csv && rm -f $ZOO_DIR/results/recent_csv/*" 2>/dev/null

# Start /proc/stat CPU monitor on each server (background)
# Samples per-core and overall CPU every 1s, writes to a file
echo "[$LABEL] Starting CPU monitors on all hosts..."
CPU_MONITOR_DURATION=$((DURATION + 15))
CPU_MONITOR_SCRIPT='
DURATION='"$CPU_MONITOR_DURATION"'
for t in $(seq 1 $DURATION); do
    ts=$(date +%s)
    echo "T=$ts"
    head -66 /proc/stat | grep -E "^cpu"
    sleep 1
done
'
for i in "${!servers[@]}"; do
    ssh "$SERVER_USERNAME@${servers[$i]}" "$CPU_MONITOR_SCRIPT" \
        > "$RESULT_DIR/${LABEL}-${replicanames[$i]}-cpustat.txt" 2>&1 &
done

sleep 1  # let monitors start

# Build server command
# Use the packaged ld-linux-x86-64.so.2 explicitly so this works on hosts whose
# system glibc is newer than the docker_libs glibc (e.g. Debian trixie 2.41 vs
# our Ubuntu 22.04 2.35). Setting only LD_LIBRARY_PATH is insufficient because
# the system dynamic linker is what gets invoked first.
SERVER_CMD="export LD_LIBRARY_PATH=${ZOO_DIR}/build/docker_libs:\${HOME}/local/lib:\${LD_LIBRARY_PATH}; export WAN_DELAY_MS=20; export SERVER_CORE_ID=${SERVER_CORE_ID}; cd $ZOO_DIR && ${ZOO_DIR}/build/docker_libs/ld-linux-x86-64.so.2 build/deptran_server -f config/${PROTOCOL_CFG} -f config/client_open.yml -f config/${CLIENT_CFG} -f config/${WORKLOAD_CFG} -f config/${CONC_CFG} -m ${MODE} -d ${DURATION}"

echo "[$LABEL] Command: $SERVER_CMD"
echo "[$LABEL] Starting experiment..."

declare -a jobs
for i in "${!servers[@]}"; do
    output_file="$RESULT_DIR/${LABEL}-${replicanames[$i]}.res"
    run_name="${LABEL}-${replicanames[$i]}"
    timeout "${TIMEOUT_SEC}s" \
        ssh "$SERVER_USERNAME@${servers[$i]}" \
            "${SERVER_CMD} -P ${replicanames[$i]} -N ${run_name}" \
        > "$output_file" 2>&1 &
    jobs[$i]=$!
done

# Wait for all experiment processes
for i in "${!jobs[@]}"; do
    pid=${jobs[$i]}
    if wait "$pid"; then
        echo "[$LABEL] ${replicanames[$i]} completed."
    else
        status=$?
        if [[ $status -eq 124 ]]; then
            echo "[$LABEL] ${replicanames[$i]} TIMED OUT."
        else
            echo "[$LABEL] ${replicanames[$i]} exit code $status."
        fi
    fi
done

# Kill any lingering processes
for ip in "${servers[@]}"; do
    ssh "$SERVER_USERNAME@$ip" "pkill -9 deptran_server" &>/dev/null &
done
wait
sleep 2

# Flush NFS
for ip in "${servers[@]}"; do
    ssh "$SERVER_USERNAME@$ip" "sync" &>/dev/null &
done
wait
sleep 3

# Wait for the per-host .res files to actually contain "Mid throughput is"
# before the caller parses them. The line is now written BEFORE s_main's
# defensive sleep(10) (verified on 2026-05-03 saturated run), so it's
# usually present immediately when the SSH job exits. Cap at 10s rather
# than 30s — the previous 30s cap was almost never consumed.
for i in "${!servers[@]}"; do
    resfile="$RESULT_DIR/${LABEL}-${replicanames[$i]}.res"
    for _ in $(seq 1 10); do
        if [ -f "$resfile" ] && tail -c 102400 "$resfile" | grep -q "Mid throughput is"; then
            break
        fi
        sleep 1
    done
done

# Pull CSV results
scp "$SERVER_USERNAME@${servers[0]}:$ZOO_DIR/results/recent_csv/${LABEL}-*" "$RESULT_DIR/" 2>/dev/null || true
scp "$SERVER_USERNAME@${servers[0]}:$ZOO_DIR/results/recent_csv/tdigest_${LABEL}-*" "$RESULT_DIR/" 2>/dev/null || true

# Check success
SUCCESS=true
for i in "${!servers[@]}"; do
    resfile="$RESULT_DIR/${LABEL}-${replicanames[$i]}.res"
    if [ -f "$resfile" ] && tail -c 102400 "$resfile" | grep -q "Mid throughput is"; then
        echo "[$LABEL] ${replicanames[$i]}: OK"
    else
        echo "[$LABEL] ${replicanames[$i]}: FAILED"
        SUCCESS=false
    fi
done

# Parse and display results summary
echo ""
echo "=== [$LABEL] Results Summary ==="
TOTAL_TPUT=0
for i in "${!servers[@]}"; do
    resfile="$RESULT_DIR/${LABEL}-${replicanames[$i]}.res"
    if [ -f "$resfile" ]; then
        tp=$(tail -c 102400 "$resfile" | grep -m1 "Mid throughput is" | awk '{print $NF}' 2>/dev/null || echo "0")
        TOTAL_TPUT=$(echo "$TOTAL_TPUT + $tp" | bc 2>/dev/null || echo "$TOTAL_TPUT")
        echo "  ${replicanames[$i]}: throughput=$tp"
    fi
done
echo "  Total throughput: $TOTAL_TPUT"

# Extract latency from zoo1 (any replica reports it)
RESFILE0="$RESULT_DIR/${LABEL}-zoo1.res"
if [ -f "$RESFILE0" ]; then
    echo ""
    tail -c 102400 "$RESFILE0" | grep -E "All-efficient-attempts|Fastpath statistics|Cpu-usage-leaders|server median" || true
fi

# Parse /proc/stat CPU data: compute per-core and host-level CPU usage
echo ""
echo "=== [$LABEL] CPU Usage (core ${SERVER_CORE_ID} = server thread) ==="

parse_cpu_usage() {
    local cpustat_file="$1"
    local core_name="$2"  # e.g. "cpu1" for core 1, "cpu " for aggregate

    # Extract all lines matching core_name, compute usage between consecutive samples
    local prev_total=0 prev_idle=0 first=1
    local usages=()

    while IFS= read -r line; do
        # Format: cpuN user nice system idle iowait irq softirq steal
        read -r _ user nice system idle iowait irq softirq steal <<< "$line"
        total=$((user + nice + system + idle + iowait + irq + softirq + steal))

        if [ $first -eq 1 ]; then
            first=0
        else
            dtotal=$((total - prev_total))
            didle=$((idle + iowait - prev_idle))
            if [ $dtotal -gt 0 ]; then
                usage=$(echo "scale=1; 100 * (1 - $didle / $dtotal)" | bc 2>/dev/null)
                usages+=("$usage")
            fi
        fi
        prev_total=$total
        prev_idle=$((idle + iowait))
    done < <(grep "^${core_name}" "$cpustat_file" 2>/dev/null)

    if [ ${#usages[@]} -gt 0 ]; then
        avg=$(printf '%s\n' "${usages[@]}" | awk '{s+=$1; n++} END {if(n>0) printf "%.1f", s/n; else print "N/A"}')
        max=$(printf '%s\n' "${usages[@]}" | sort -n | tail -1)
        echo "${avg} ${max}"
    else
        echo "N/A N/A"
    fi
}

for i in "${!servers[@]}"; do
    cpufile="$RESULT_DIR/${LABEL}-${replicanames[$i]}-cpustat.txt"
    if [ -f "$cpufile" ] && [ -s "$cpufile" ]; then
        read -r core_avg core_max <<< "$(parse_cpu_usage "$cpufile" "${SERVER_CPU_ROW}")"
        read -r host_avg host_max <<< "$(parse_cpu_usage "$cpufile" "cpu ")"
        echo "  ${replicanames[$i]}: core${SERVER_CORE_ID} avg=${core_avg}% max=${core_max}%  |  host avg=${host_avg}% max=${host_max}%"
    else
        echo "  ${replicanames[$i]}: no CPU data"
    fi
done

echo ""
echo "=== [$LABEL] Done ==="
