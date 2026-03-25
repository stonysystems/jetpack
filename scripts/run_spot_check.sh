#!/bin/bash
#
# Run targeted spot-check experiments for specific protocol+concurrency pairs.
# Unlike 10-run_all.sh which runs the full matrix, this runs only the configs
# you specify, saving results to an existing experiment directory.
#
# Usage:
#   bash scripts/run_spot_check.sh --exp-dir <result_dir> --configs <config_file>
#   bash scripts/run_spot_check.sh --exp-dir <result_dir> --protocol <proto> --concs <c1,c2,...>
#
# Config file format (one per line):
#   <site>,<protocol>,<workload>,<concurrency>,<fastpath_mode>,<ycsb>
#
# Examples:
#   # Run specific configs from a file
#   bash scripts/run_spot_check.sh --exp-dir results/2026-03-23-10:26:07-zoo-5machines \
#       --configs /tmp/spot_check_configs.txt
#
#   # Run all modes for a protocol at specific concurrencies
#   bash scripts/run_spot_check.sh --exp-dir results/2026-03-23-10:26:07-zoo-5machines \
#       --protocol etcd --concs concurrent_140,concurrent_200,concurrent_300
#
#   # Dry run to see what would be executed
#   bash scripts/run_spot_check.sh --exp-dir results/2026-03-23-10:26:07-zoo-5machines \
#       --protocol etcd --concs concurrent_140 --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse arguments
DRY_RUN=false
EXP_DIR=""
CONFIG_FILE=""
PROTOCOL_FILTER=""
CONC_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --exp-dir)
            EXP_DIR="$2"; shift 2 ;;
        --configs)
            CONFIG_FILE="$2"; shift 2 ;;
        --protocol)
            PROTOCOL_FILTER="$2"; shift 2 ;;
        --concs)
            CONC_FILTER="$2"; shift 2 ;;
        --dry-run|-n)
            DRY_RUN=true; shift ;;
        --help|-h)
            echo "Usage: $0 --exp-dir <dir> [--configs <file>] [--protocol <proto> --concs <c1,c2>] [--dry-run]"
            exit 0 ;;
        *) shift ;;
    esac
done

if [[ -z "$EXP_DIR" ]]; then
    echo "Error: --exp-dir is required"
    exit 1
fi

# Resolve to absolute path
if [[ "$EXP_DIR" != /* ]]; then
    EXP_DIR="$REPO_ROOT/$EXP_DIR"
fi

if [[ ! -d "$EXP_DIR" ]]; then
    echo "Error: $EXP_DIR is not a directory"
    exit 1
fi

# Read setup.json (same location as 10-run_all.sh expects it)
SETUP_JSON="${SCRIPT_DIR}/setup.json"
if [[ ! -f "$SETUP_JSON" ]]; then
    echo "Error: setup.json not found at $SETUP_JSON"
    exit 1
fi

SERVER_USERNAME=$(jq -r '.server_username' "$SETUP_JSON")
N_SERVER=$(jq -r '.n_server' "$SETUP_JSON")
environment=$(jq -r '.environment' "$SETUP_JSON")
if [[ "$environment" == "zoo" ]]; then
    repo_dir=$(jq -r '.zoo_directory' "$SETUP_JSON")
else
    repo_dir="/home/ubuntu/code/JetPack"
fi

# Build server arrays
declare -a servers replicanames
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip=$(jq -r ".servers[$i][\"server_${i}_ip\"]" "$SETUP_JSON")
    if [[ "$environment" == "zoo" ]]; then
        name_var="zoo${i}"
    else
        name_var="server${i}"
    fi
    servers+=("$server_ip")
    replicanames+=("$name_var")
done

MAX_RES_SIZE_BYTES=$((50 * 1024 * 1024))

# Source experiment definitions
source "${SCRIPT_DIR}/experiment_defs.sh"

TIMEOUT_SEC=$((5 * 60))  # 5 minutes — high concurrency experiments need more time
SITE="${SITE_ZOO_SWEEP}"

# Execute a single experiment config (same logic as 10-run_all.sh)
execute_command() {
    local site=$1 protocol=$2 workload=$3 concurrent=$4 fastpath_mode=$5 ycsb=$6

    local exp_name
    exp_name=$(build_result_prefix "$protocol" "$site" "$workload" "$concurrent" "$fastpath_mode" "$ycsb")
    local server_command
    server_command=$(build_deptran_cmd "$repo_dir" "$protocol" "$site" "$workload" "$concurrent" "$fastpath_mode" "30" "$ycsb" "")

    if [[ "$environment" == "zoo" ]]; then
        server_command="export LD_LIBRARY_PATH=\${HOME}/local/lib:\${LD_LIBRARY_PATH}; export WAN_DELAY_MS=20; ${server_command}"
    fi

    # Clean up previous processes
    for ip in "${servers[@]}"; do
        ssh "${SERVER_USERNAME}@${ip}" "pkill -9 deptran_server 2>/dev/null; rm -f /tmp/JM_*" &>/dev/null || true
    done
    sleep 1

    for i in "${!servers[@]}"; do
        local output_file="${EXP_DIR}/${exp_name}-${replicanames[$i]}.res"
        timeout "${TIMEOUT_SEC}s" \
            ssh "${SERVER_USERNAME}@${servers[$i]}" \
                "${server_command} -N ${exp_name}-${replicanames[$i]} -P ${replicanames[$i]} > ${output_file}" &
    done
    wait

    # Kill lingering processes
    for i in "${!servers[@]}"; do
        ssh "${SERVER_USERNAME}@${servers[$i]}" "pkill -9 deptran_server" &>/dev/null || true
    done

    # Flush NFS write-behind cache before scp (see scp_race_audit.py)
    for ip in "${servers[@]}"; do
        ssh "${SERVER_USERNAME}@${ip}" "sync" &>/dev/null &
    done
    wait
    sleep 3

    # Collect results — use relative exp_dir path for remote scp
    local remote_exp_dir="${EXP_DIR}"
    # If exp_dir is under repo_dir, make it relative to repo_dir for remote path
    if [[ "$EXP_DIR" == "${repo_dir}/"* ]]; then
        remote_exp_dir="${EXP_DIR#${repo_dir}/}"
    fi
    scp "${SERVER_USERNAME}@${servers[0]}:${repo_dir}/${remote_exp_dir}/${exp_name}-*" "${EXP_DIR}" &
    scp "${SERVER_USERNAME}@${servers[0]}:${repo_dir}/results/recent_csv/${exp_name}-*" "${EXP_DIR}" &
    scp "${SERVER_USERNAME}@${servers[0]}:${repo_dir}/results/recent_csv/tdigest_${exp_name}-*" "${EXP_DIR}" &
    wait

    # Check results
    local status=0 fail_reason=""
    for i in "${!servers[@]}"; do
        local to_check_file="${EXP_DIR}/${exp_name}-${replicanames[$i]}.res"
        if [[ ! -f "$to_check_file" ]]; then
            status=1; fail_reason="missing file"; continue
        fi
        local file_size
        file_size=$(stat -c%s "$to_check_file" 2>/dev/null || echo 0)
        if [[ "$file_size" -gt "$MAX_RES_SIZE_BYTES" ]]; then
            status=1; fail_reason="oversized file"; continue
        fi
        if grep -q "Mid throughput is" "$to_check_file" && \
           grep -q "Dumped to" "$to_check_file" && \
           ! grep -q "generic server error" "$to_check_file"; then
            local mid_tp
            mid_tp=$(grep -m1 "Mid throughput is" "$to_check_file" | awk '{print $NF}' || echo 0)
            mid_tp=${mid_tp:-0}
            if [[ "$workload" == "rw_1000000" ]]; then
                if [[ "$(printf '%.0f' "${mid_tp}" 2>/dev/null || echo 0)" -lt 1 ]]; then
                    status=1; fail_reason="low throughput (${mid_tp})"
                fi
            fi
            # Verify CSV artifact is present locally after scp
            local csv_file="${EXP_DIR}/${exp_name}-${replicanames[$i]}.csv"
            if [[ ! -f "$csv_file" ]]; then
                status=1; fail_reason="csv_missing_after_scp"
            fi
        else
            status=1; fail_reason="missing success markers"
        fi
    done

    if [[ $status -eq 1 ]]; then
        echo "FAIL ${exp_name} (${fail_reason})"
        return 1
    else
        local tp
        tp=$(grep -m1 "Mid throughput is" "${EXP_DIR}/${exp_name}-${replicanames[0]}.res" | awk '{print $NF}' 2>/dev/null || echo "?")
        echo "OK   ${exp_name}  throughput=${tp}"
        return 0
    fi
}

# Build config list
declare -a configs=()

if [[ -n "$CONFIG_FILE" ]]; then
    # Read configs from file
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        configs+=("$line")
    done < "$CONFIG_FILE"

elif [[ -n "$PROTOCOL_FILTER" && -n "$CONC_FILTER" ]]; then
    # Generate configs for a protocol family at specific concurrencies
    IFS=',' read -ra conc_list <<< "$CONC_FILTER"
    proto_family="$PROTOCOL_FILTER"

    for conc in "${conc_list[@]}"; do
        # Original protocol
        configs+=("${SITE},none_${proto_family},rw_1000000,${conc},0,YCSB_A")
        # Jetpack protocol: modes 0, 100, 101
        for mode in 0 100 101; do
            configs+=("${SITE},rule_${proto_family},rw_1000000,${conc},${mode},YCSB_A")
        done
    done
else
    echo "Error: specify either --configs <file> or --protocol <proto> --concs <c1,c2,...>"
    exit 1
fi

num_configs=${#configs[@]}
echo "=== Spot Check ==="
echo "Exp dir:  $EXP_DIR"
echo "Configs:  $num_configs"
echo "Timeout:  ${TIMEOUT_SEC}s per run"
echo "Servers:  ${#servers[@]} (${servers[*]})"
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo "--- DRY RUN ---"
    for cfg in "${configs[@]}"; do
        echo "  $cfg"
    done
    est_seconds=$((num_configs * 85))
    est_min=$((est_seconds / 60))
    echo ""
    echo "Estimated time: ~${est_min} minutes"
    echo "=== END DRY RUN ==="
    exit 0
fi

# Execute
SECONDS=0
pass=0 fail=0
declare -a failed_configs=()

for idx in "${!configs[@]}"; do
    IFS=',' read -r site protocol workload concurrent fastpath_mode ycsb <<< "${configs[$idx]}"
    echo "[$(( idx + 1 ))/${num_configs}] ${protocol} ${concurrent} mode=${fastpath_mode}"
    if execute_command "$site" "$protocol" "$workload" "$concurrent" "$fastpath_mode" "$ycsb"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        failed_configs+=("${configs[$idx]}")
    fi
done

# Summary
elapsed=$SECONDS
el_min=$((elapsed / 60))
el_sec=$((elapsed % 60))

echo ""
echo "=== Spot Check Complete ==="
echo "Pass: $pass  Fail: $fail  Total: $num_configs"
echo "Elapsed: ${el_min}m ${el_sec}s"

if [[ ${#failed_configs[@]} -gt 0 ]]; then
    echo ""
    echo "Failed configs:"
    for fc in "${failed_configs[@]}"; do
        echo "  $fc"
    done
fi

# Save spot check log
SPOT_LOG="${EXP_DIR}/spot_check_$(date +%Y%m%d_%H%M%S).log"
{
    echo "Spot check: $(date)"
    echo "Pass: $pass  Fail: $fail  Total: $num_configs"
    echo "Elapsed: ${el_min}m ${el_sec}s"
    echo ""
    echo "Configs run:"
    for cfg in "${configs[@]}"; do
        echo "  $cfg"
    done
    if [[ ${#failed_configs[@]} -gt 0 ]]; then
        echo ""
        echo "Failed:"
        for fc in "${failed_configs[@]}"; do
            echo "  $fc"
        done
    fi
} > "$SPOT_LOG"
echo "Log saved: $SPOT_LOG"
