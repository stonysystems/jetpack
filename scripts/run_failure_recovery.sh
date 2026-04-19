#!/bin/bash
# run_failure_recovery.sh — Run Zoo failure-recovery experiments for Track 6
#
# Executes 4 failure-recovery runs (rule_raft, rule_mongodb, rule_etcd, rule_zookeeper)
# with real deptran_server kill on the leader node (zoo1).
#
# Prerequisites:
#   - Experiment 0 complete (fixed_conc.json exists)
#   - Zoo cluster accessible
#   - No other experiments running on the cluster
#
# Usage: bash scripts/run_failure_recovery.sh [--dry-run] [--exp-dir <path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/experiment_defs.sh"

DRY_RUN=false
EXP_DIR=""
KILL_DELAY=40    # seconds into run before killing leader (must exceed client init time ~25s)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-n) DRY_RUN=true; shift ;;
        --exp-dir) EXP_DIR="$2"; shift 2 ;;
        --kill-delay) KILL_DELAY="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Read setup.json
if [ ! -f "${SCRIPT_DIR}/setup.json" ]; then
    echo "setup.json not found in ${SCRIPT_DIR}"
    exit 1
fi
SERVER_USERNAME=$(jq -r '.server_username' "${SCRIPT_DIR}/setup.json")
N_SERVER=$(jq -r '.n_server' "${SCRIPT_DIR}/setup.json")
environment=$(jq -r '.environment' "${SCRIPT_DIR}/setup.json")
repo_dir=$(jq -r '.zoo_directory' "${SCRIPT_DIR}/setup.json")

# Build server list
declare -a servers replicanames
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip=$(jq -r ".servers[$i][\"server_${i}_ip\"]" "${SCRIPT_DIR}/setup.json")
    servers+=("${server_ip}")
    replicanames+=("zoo${i}")
done

# Load fixed concurrencies
FIXED_CONC_JSON="${SCRIPT_DIR}/../results/fixed_conc.json"
if [[ ! -f "$FIXED_CONC_JSON" ]]; then
    echo "ERROR: fixed_conc.json not found. Run experiment 0 first."
    exit 1
fi

# Protocol configs for failure recovery: protocol, fixed_conc_key, client_config
declare -a FR_PROTOCOLS=("rule_raft" "rule_mongodb" "rule_etcd" "rule_zookeeper")
declare -a FR_CONC_KEYS=("none_raft" "none_mongodb" "none_etcd" "none_zookeeper")
declare -a FR_CLIENT_CONFIGS=("client_open_failure_recovery.yml" "client_open_failure_recovery.yml" "client_open_failure_recovery.yml" "client_open_failure_recovery.yml")

# Set up result directory
if [[ -z "$EXP_DIR" ]]; then
    EXP_DIR="results/$(date +%Y-%m-%d-%H:%M:%S)-zoo-5machines"
fi
mkdir -p "$EXP_DIR/failure_recovery"

TIMEOUT_SEC=300  # 5 minutes for failure recovery (longer duration=70s + recovery time)
DURATION=90

echo "=== Zoo Failure Recovery Experiments ==="
echo "Protocols: ${FR_PROTOCOLS[*]}"
echo "Kill target: zoo1 (leader, locale_id 0)"
echo "Kill delay: ${KILL_DELAY}s"
echo "Duration: ${DURATION}s"
echo "Result dir: $EXP_DIR/failure_recovery"
echo ""

for idx in "${!FR_PROTOCOLS[@]}"; do
    protocol="${FR_PROTOCOLS[$idx]}"
    conc_key="${FR_CONC_KEYS[$idx]}"
    client_config="${FR_CLIENT_CONFIGS[$idx]}"

    # Get fixed concurrency
    fixed_conc=$(jq -r ".[\"${conc_key}\"]" "$FIXED_CONC_JSON")
    if [[ -z "$fixed_conc" || "$fixed_conc" == "null" ]]; then
        echo "WARNING: no fixed conc for $conc_key, using concurrent_50"
        fixed_conc="concurrent_50"
    fi

    exp_name="${protocol}-30c1s5r5p-zoo-rw_1000000-${fixed_conc}-101-YCSB_A-recovery"
    fr_dir="$EXP_DIR/failure_recovery"

    echo "--- Running failure recovery: $protocol @ $fixed_conc ---"

    server_command="export LD_LIBRARY_PATH=\${HOME}/local/lib:\${LD_LIBRARY_PATH}; export WAN_DELAY_MS=20; cd $repo_dir && build/deptran_server"
    server_command+=" -f config/${protocol}.yml"
    server_command+=" -f config/${client_config}"
    server_command+=" -f config/30c1s5r5p-zoo.yml"
    server_command+=" -f config/rw_1000000.yml"
    server_command+=" -f config/${fixed_conc}.yml"
    server_command+=" -f config/YCSB_A.yml"
    server_command+=" -f config/failover.yml"
    server_command+=" -m 101 -d ${DURATION}"

    if [ "$DRY_RUN" = true ]; then
        echo "  Command: $server_command"
        echo "  Kill: ssh $SERVER_USERNAME@${servers[0]} 'pkill -9 deptran_server' after ${KILL_DELAY}s"
        echo ""
        continue
    fi

    # Clean up before starting
    for ip in "${servers[@]}"; do
        ssh "${SERVER_USERNAME}@${ip}" "pkill -9 deptran_server 2>/dev/null; rm -f /tmp/JM_*" &>/dev/null || true
    done
    sleep 2

    # Record pre-kill PIDs on target server
    pre_kill_pids=$(ssh "${SERVER_USERNAME}@${servers[0]}" "pgrep deptran_server 2>/dev/null || echo none")

    # Launch experiment on all 5 servers
    for i in "${!servers[@]}"; do
        output_file="${fr_dir}/${exp_name}-${replicanames[$i]}.res"
        timeout "${TIMEOUT_SEC}s" \
            ssh "${SERVER_USERNAME}@${servers[$i]}" \
                "${server_command} -N ${exp_name}-${replicanames[$i]} -P ${replicanames[$i]} > ${output_file} 2>&1" &
    done

    # Background kill job: wait KILL_DELAY seconds, then kill leader
    (
        sleep "$KILL_DELAY"
        kill_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        target_host="${servers[0]}"
        target_replica="${replicanames[0]}"

        # Get PID before kill
        pre_pid=$(ssh "${SERVER_USERNAME}@${target_host}" "pgrep -o deptran_server 2>/dev/null || echo none")

        # Kill!
        ssh "${SERVER_USERNAME}@${target_host}" "pkill -9 deptran_server" 2>/dev/null || true
        sleep 1

        # Verify kill
        post_pid=$(ssh "${SERVER_USERNAME}@${target_host}" "pgrep deptran_server 2>/dev/null || echo none")

        # Save evidence
        cat > "${fr_dir}/${exp_name}-kill_evidence.json" <<EVIDENCE
{
    "protocol": "${protocol}",
    "target_host": "${target_host}",
    "target_replica": "${target_replica}",
    "kill_timestamp": "${kill_timestamp}",
    "kill_command": "pkill -9 deptran_server",
    "kill_delay_seconds": ${KILL_DELAY},
    "pre_kill_pid": "${pre_pid}",
    "post_kill_pid": "${post_pid}",
    "confirmed_dead": $([ "$post_pid" = "none" ] && echo "true" || echo "false")
}
EVIDENCE
        echo "[$protocol] Kill evidence saved: pre_pid=$pre_pid post_pid=$post_pid"
    ) &

    # Wait for all SSH processes and kill job to finish
    wait

    # Post-experiment cleanup
    for ip in "${servers[@]}"; do
        ssh "${SERVER_USERNAME}@${ip}" "pkill -9 deptran_server" &>/dev/null || true
    done
    sleep 1

    # Flush NFS write-behind cache before pulling CSV files
    for ip in "${servers[@]}"; do
        ssh "${SERVER_USERNAME}@${ip}" "sync" &>/dev/null &
    done
    wait
    sleep 3  # NFS attribute cache propagation

    # Pull CSV files
    scp "${SERVER_USERNAME}@${servers[0]}:${repo_dir}/results/recent_csv/${exp_name}-*" "${fr_dir}/" 2>/dev/null || true
    scp "${SERVER_USERNAME}@${servers[0]}:${repo_dir}/results/recent_csv/tdigest_${exp_name}-*" "${fr_dir}/" 2>/dev/null || true

    # Check results
    success_count=0
    for i in "${!servers[@]}"; do
        res_file="${fr_dir}/${exp_name}-${replicanames[$i]}.res"
        if [ -f "$res_file" ] && tail -c 102400 "$res_file" | grep -q "Mid throughput is"; then
            success_count=$((success_count + 1))
        fi
    done

    # The killed server (zoo1) won't have throughput markers, so expect 4/5
    if [ "$success_count" -ge 4 ]; then
        echo "[$protocol] SUCCESS: $success_count/5 servers have throughput data (1 was killed)"
    elif [ "$success_count" -ge 3 ]; then
        echo "[$protocol] PARTIAL: $success_count/5 servers have throughput data"
    else
        echo "[$protocol] FAIL: only $success_count/5 servers have throughput data"
    fi
    echo ""
done

# Generate recovery summary report
cat > "$EXP_DIR/failure_recovery/RECOVERY_SUMMARY.md" <<'HEADER'
# Zoo Failure Recovery Summary

## Experiment Parameters
- Kill target: zoo1 (130.245.173.101, locale_id 0, leader)
- Kill method: `pkill -9 deptran_server` via SSH
- WAN latency: 20ms one-way (WAN_DELAY_MS=20)
- Client mode: open-loop (client_open_failure_recovery.yml)
- Failover config: failover.yml (soft failover, 15s interval)

## Per-Protocol Results
HEADER

for idx in "${!FR_PROTOCOLS[@]}"; do
    protocol="${FR_PROTOCOLS[$idx]}"
    conc_key="${FR_CONC_KEYS[$idx]}"
    fixed_conc=$(jq -r ".[\"${conc_key}\"]" "$FIXED_CONC_JSON")
    exp_name="${protocol}-30c1s5r5p-zoo-rw_1000000-${fixed_conc}-101-YCSB_A-recovery"

    echo "" >> "$EXP_DIR/failure_recovery/RECOVERY_SUMMARY.md"
    echo "### ${protocol}" >> "$EXP_DIR/failure_recovery/RECOVERY_SUMMARY.md"
    echo "- Fixed concurrency: ${fixed_conc}" >> "$EXP_DIR/failure_recovery/RECOVERY_SUMMARY.md"

    evidence_file="${EXP_DIR}/failure_recovery/${exp_name}-kill_evidence.json"
    if [ -f "$evidence_file" ]; then
        echo "- Kill evidence: $(cat "$evidence_file" | jq -c .)" >> "$EXP_DIR/failure_recovery/RECOVERY_SUMMARY.md"
    fi

    # Extract throughput from surviving servers
    for i in 1 2 3 4; do
        res_file="${EXP_DIR}/failure_recovery/${exp_name}-${replicanames[$i]}.res"
        if [ -f "$res_file" ]; then
            tp=$(tail -c 102400 "$res_file" | grep -m1 "Mid throughput is" | awk '{print $NF}' 2>/dev/null || echo "N/A")
            echo "- ${replicanames[$i]} throughput: ${tp}" >> "$EXP_DIR/failure_recovery/RECOVERY_SUMMARY.md"
        fi
    done
done

echo ""
echo "=== Failure recovery experiments complete ==="
echo "Evidence dir: $EXP_DIR/failure_recovery"
echo "Summary: $EXP_DIR/failure_recovery/RECOVERY_SUMMARY.md"
