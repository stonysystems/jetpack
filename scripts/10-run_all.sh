#!/bin/bash

# Parse CLI arguments
DRY_RUN=false
BUILD_ARG=""
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n)
            DRY_RUN=true
            ;;
        full|build)
            BUILD_ARG="$arg"
            ;;
        --help|-h)
            echo "Usage: $0 [full|build] [--dry-run]"
            echo ""
            echo "Options:"
            echo "  full        Regenerate RPC + build before running"
            echo "  build       Build before running"
            echo "  --dry-run   Print experiment matrix without executing"
            exit 0
            ;;
    esac
done

# Check if setup.json exists and read values from it
if [ -f "setup.json" ]; then
    SERVER_USERNAME=$(jq -r '.server_username' setup.json)
    N_SERVER=$(jq -r '.n_server' setup.json)
    environment=$(jq -r '.environment' setup.json)
    if [ "$environment" == "zoo" ]; then
        repo_dir=$(jq -r '.zoo_directory' setup.json)
    else
        repo_dir="/home/ubuntu/code/JetPack"
    fi
else
    echo "setup.json not found. Exiting."
    exit 1
fi

# Define an array of server IP addresses and replica names dynamically
declare -a servers
declare -a replicanames

# Populate the servers and replicanames arrays based on N_SERVER
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip=$(jq -r ".servers[$i][\"server_${i}_ip\"]" setup.json)
    name_var="server${i}"
    servers+=("${server_ip}")
    replicanames+=("${name_var}")
done

MAX_RES_SIZE_BYTES=$((50 * 1024 * 1024))  # res files usually should be ~10MB

# Source centralized experiment definitions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/experiment_defs.sh"

# Experiment configs — use centralized definitions from experiment_defs.sh.
# Select protocol families and site based on the environment.
if [ "$environment" == "zoo" ]; then
    declare -a jetpack_protocols=("${ZOO_JETPACK_PROTOCOLS[@]}")
    declare -a origin_protocols=("${ZOO_ORIGIN_PROTOCOLS[@]}")
    declare -a sites=("$SITE_ZOO_SWEEP")
    declare -a concurrents=("${ZOO_CONCS_ARRAYS[@]}")

    # Load Zoo fixed concurrencies if available (for experiments 1 and 2).
    FIXED_CONC_JSON="${SCRIPT_DIR}/../results/fixed_conc.json"
    if [[ -f "$FIXED_CONC_JSON" ]]; then
        load_zoo_fixed_concs "$FIXED_CONC_JSON"
        declare -a fixed_concurrents=("${ZOO_FIXED_CONCS[@]}")
    else
        # Placeholder — experiment 0 must run first to derive these.
        declare -a fixed_concurrents=()
    fi
else
    declare -a jetpack_protocols=("${LEGACY_JETPACK_PROTOCOLS[@]}")
    declare -a origin_protocols=("${LEGACY_ORIGIN_PROTOCOLS[@]}")
    declare -a sites=("$SITE_AWS_SWEEP")
    declare -a concurrents=("RAFT_CONCS" "COPILOT_CONCS" "MENCIUS_CONCS" "MONGODB_CONCS")
    declare -a fixed_concurrents=("${LEGACY_FIXED_CONCS[@]}")
fi

declare -a workloads=("rw_1000000")
declare -a ycsbs=("YCSB_A")
declare -a zipf_workloads=(
    rw_zipf_1 rw_zipf_0.9 rw_zipf_0.8
    rw_zipf_0.7 rw_zipf_0.6 rw_zipf_0.5
)
declare -a key_range_workloads=(rw_1 rw_10 rw_100 rw_1000 rw_10000 rw_100000 rw_1000000)

# Protocol-specific concurrency arrays from experiment_defs.sh
declare -a raft_concs=("${RAFT_CONCS[@]}")
declare -a copilot_concs=("${COPILOT_CONCS[@]}")
declare -a mencius_concs=("${MENCIUS_CONCS[@]}")
declare -a mongodb_concs=("${MONGODB_CONCS[@]}")
declare -a etcd_concs=("${ETCD_CONCS[@]}")
declare -a zookeeper_concs=("${ZOOKEEPER_CONCS[@]}")
declare -a fastpath_modes=("${ALL_FASTPATH_MODES[@]}")


# Build commands
if [[ "$BUILD_ARG" == "full" ]]; then
    initial_commands="cd ${repo_dir} && bin/rpcgen --python --cpp src/deptran/rcc_rpc.rpc && python3 add_virtual.py && python3 waf configure build"
elif [[ "$BUILD_ARG" == "build" ]]; then
    initial_commands="cd ${repo_dir} && python3 waf configure build"
else
    initial_commands="cd ${repo_dir}"
fi

# Skip remote setup in dry-run mode
if [ "$DRY_RUN" != true ]; then
    # Execute initial commands on SERVER_0
    echo "Executing initial setup on ${servers[0]}..."
    ssh ${SERVER_USERNAME}@"${servers[0]}" "$initial_commands"

    # Get the current date and time in the specified format
    current_time=$(date "+%Y-%m-%d-%H:%M:%S")

    # Get the latest git commit hash
    get_commit_hash_cmd="cd $repo_dir && git rev-parse HEAD"
    latest_commit_hash=$(ssh "${SERVER_USERNAME}@${servers[0]}" "$get_commit_hash_cmd")

    if [ -z "$latest_commit_hash" ]; then
        echo "Failed to retrieve the latest commit hash. Exiting."
        exit 1
    else
        echo "Latest commit hash: $latest_commit_hash"
    fi

    # Construct the directory path.
    # Zoo runs use the required naming format; AWS uses the legacy format.
    if [ "$environment" == "zoo" ]; then
        exp_dir="results/${current_time}-zoo-5machines"
    else
        exp_dir="results/${current_time}-${latest_commit_hash}"
    fi
    mkdir -p "$exp_dir"

    # Save git commit hash in metadata file (not in directory name for Zoo)
    echo "{\"commit\": \"${latest_commit_hash}\", \"started_at\": \"${current_time}\", \"environment\": \"${environment}\"}" > "${exp_dir}/metadata.json"

    echo "Experiment directory created: $exp_dir"
    ssh ${SERVER_USERNAME}@"${servers[0]}" "cd ${repo_dir} && mkdir -p ${exp_dir} && mkdir -p results/recent_csv && rm results/recent_csv/*"
fi

declare -a all_configs todo_configs

TIMEOUT_SEC=$((3 * 60)) # 3 minutes per experiment run on each server

# Function to execute commands on servers
execute_command() {
    local site=$1
    local protocol=$2
    local workload=$3
    local concurrent=$4
    local fastpath_mode=$5
    local ycsb=$6

    exp_name=$(build_result_prefix "$protocol" "$site" "$workload" "$concurrent" "$fastpath_mode" "$ycsb")
    server_command=$(build_deptran_cmd "$repo_dir" "$protocol" "$site" "$workload" "$concurrent" "$fastpath_mode" "30" "$ycsb" "")

    # For Zoo, prepend LD_LIBRARY_PATH for locally-installed third-party libs
    if [ "$environment" == "zoo" ]; then
        server_command="export LD_LIBRARY_PATH=\${HOME}/local/lib:\${LD_LIBRARY_PATH}; ${server_command}"
    fi

    # Clean up any previous JM_Jetpack_* files before starting a new run
    local cleanup_target
    cleanup_target="/tmp/JM_*"

    local -a cleanup_pids=()
    for ip in "${servers[@]}"; do
        {
            echo "[$ip] Cleaning JM_Jetpack_*..."
            if ssh "${SERVER_USERNAME}@${ip}" "rm -f $cleanup_target"; then
                echo "[$ip] Cleanup OK"
            else
                echo "[$ip] Cleanup FAILED"
            fi
        } &
        cleanup_pids+=($!)
    done

    for pid in "${cleanup_pids[@]}"; do
        wait "$pid"
    done

    for i in "${!servers[@]}"; do
        output_file="${exp_dir}/${exp_name}-${replicanames[$i]}.res"
        timeout "${TIMEOUT_SEC}s" \
            ssh ${SERVER_USERNAME}@"${servers[$i]}" \
                "${server_command} -N ${exp_name}-${replicanames[$i]} -P ${replicanames[$i]} > ${output_file}" &
    done

    wait

    for i in "${!servers[@]}"; do
        server_ip="${servers[$i]}"
        ssh ${SERVER_USERNAME}@"$server_ip" "pkill -9 -f deptran_server" &> /dev/null &
    done

    wait

    scp ${SERVER_USERNAME}@"${servers[0]}:${repo_dir}/${exp_dir}/${exp_name}-*" "${exp_dir}" & 		# scp from svr 0 since nfs
    scp ${SERVER_USERNAME}@"${servers[0]}:${repo_dir}/results/recent_csv/${exp_name}-*" "${exp_dir}" & 	# scp from svr 0 since nfs
    scp ${SERVER_USERNAME}@"${servers[0]}:${repo_dir}/results/recent_csv/tdigest_${exp_name}-*" "${exp_dir}" & 	# scp from svr 0 since nfs

    wait

    status=0

    for i in "${!servers[@]}"; do
        to_check_file="${exp_dir}/${exp_name}-${replicanames[$i]}.res"

        # Check the output for specific strings
        if [ ! -f "${to_check_file}" ]; then
            status=1
            fail_reason="missing file"
            continue
        fi

        file_size=$(stat -c%s "${to_check_file}" 2>/dev/null || echo 0)
        if [ "${file_size}" -gt "${MAX_RES_SIZE_BYTES}" ]; then
            echo "Oversized res file (>50MB): ${to_check_file}"
            status=1
            fail_reason="oversized file"
            continue
        fi

        if grep -q "Mid throughput is" "${to_check_file}" && grep -q "Dumped to" "${to_check_file}" && ! grep -q "generic server error" "${to_check_file}"; then
            mid_tp=$(grep -m1 "Mid throughput is" "${to_check_file}" | awk '{print $NF}' || echo 0)
            mid_tp=${mid_tp:-0}
            if [ "$(printf '%.0f' "${mid_tp}" 2>/dev/null || echo 0)" -lt 1 ]; then
                status=1
                fail_reason="low throughput (${mid_tp})"
            fi
        else
            status=1
            fail_reason="missing success markers"
        fi
    done

    if [ $status -eq 1 ]; then
        if [ -z "$fail_reason" ]; then
            fail_reason="unknown"
        fi
        echo "${site} ${protocol} ${workload} ${concurrent} ${fastpath_mode} ${ycsb} fail (${fail_reason})"
        todo_configs+=("${site},${protocol},${workload},${concurrent},${fastpath_mode},${ycsb}")
    else
        echo "${site} ${protocol} ${workload} ${concurrent} ${fastpath_mode} ${ycsb} success"
    fi

}

# Main experiment execution logic
for site in "${sites[@]}"; do

    #experiment0: 4 protocols * (1 original + 2 workloads * 2 fastpath rate * n conc)
    for i in "${!origin_protocols[@]}"; do
        
        ycsb="YCSB_A"
        
        concs_array_name="${concurrents[$i]}"

        # Original protocols
        protocol="${origin_protocols[$i]}"
        for workload in "${workloads[@]}"; do
            for fastpath_mode in "0"; do
                for conc in $(eval echo \"\${${concs_array_name}[@]}\"); do
                    all_configs+=("${site},${protocol},${workload},${conc},${fastpath_mode},${ycsb}")
                done
            done
        done

        # Jetpack protocols
        protocol="${jetpack_protocols[$i]}"
        for workload in "${workloads[@]}"; do
            for fastpath_mode in "${fastpath_modes[@]}"; do
                for conc in $(eval echo \"\${${concs_array_name}[@]}\"); do
                    all_configs+=("${site},${protocol},${workload},${conc},${fastpath_mode},${ycsb}")
                done
            done
        done
    done

    # experiment1: N protocols * (1 original + ycsbs * zipf_workloads * 3 fastpath rate * 1 conc)
    # Requires fixed_concurrents to be set (from experiment 0 results).
    if [[ ${#fixed_concurrents[@]} -gt 0 ]]; then
    for i in "${!origin_protocols[@]}"; do

        concs_array_name="${concurrents[$i]}"

        # Original protocols
        protocol="${origin_protocols[$i]}"
        fastpath_mode="0"
        conc="${fixed_concurrents[$i]}"
        for workload in "${zipf_workloads[@]}"; do
            for ycsb in "${ycsbs[@]}"; do
                all_configs+=("${site},${protocol},${workload},${conc},${fastpath_mode},${ycsb}")
            done
        done

        # Jetpack protocols
        protocol="${jetpack_protocols[$i]}"
        conc="${fixed_concurrents[$i]}"
        for workload in "${zipf_workloads[@]}"; do
            for ycsb in "${ycsbs[@]}"; do
                for fastpath_mode in "${fastpath_modes[@]}"; do
                    all_configs+=("${site},${protocol},${workload},${conc},${fastpath_mode},${ycsb}")
                done
            done
        done
    done
    else
        echo "WARNING: fixed_concurrents not set, skipping experiment 1 (zipf sweep)."
    fi

    # # experiment xxx: 4 protocols * (1 ycsb * 1 workloads * 3 fastpath rate * 1 conc)
    # for i in "${!origin_protocols[@]}"; do
        
    #     concs_array_name="${concurrents[$i]}"
        
    #     # Jetpack protocols
    #     protocol="${jetpack_protocols[$i]}"
    #     conc="${fixed_concurrents[$i]}"
    #     workload="rw_zipf_0.65"
    #     ycsb="YCSB_B"

    #     for fastpath_mode in "${fastpath_modes[@]}"; do
    #         all_configs+=("${site},${protocol},${workload},${conc},${fastpath_mode},${ycsb}")
    #     done

    # done

    # experiment2: N protocols * (1 original + ycsbs * key_range_workloads * 3 fastpath rate * 1 conc)
    # Requires fixed_concurrents to be set (from experiment 0 results).
    if [[ ${#fixed_concurrents[@]} -gt 0 ]]; then
    for i in "${!origin_protocols[@]}"; do

        concs_array_name="${concurrents[$i]}"

        # Original protocols
        protocol="${origin_protocols[$i]}"
        fastpath_mode="0"
        conc="${fixed_concurrents[$i]}"
        for workload in "${key_range_workloads[@]}"; do
            for ycsb in "${ycsbs[@]}"; do
                all_configs+=("${site},${protocol},${workload},${conc},${fastpath_mode},${ycsb}")
            done
        done

        # Jetpack protocols
        protocol="${jetpack_protocols[$i]}"
        conc="${fixed_concurrents[$i]}"
        for workload in "${key_range_workloads[@]}"; do
            for ycsb in "${ycsbs[@]}"; do
                for fastpath_mode in "${fastpath_modes[@]}"; do
                    all_configs+=("${site},${protocol},${workload},${conc},${fastpath_mode},${ycsb}")
                done
            done
        done
    done
    else
        echo "WARNING: fixed_concurrents not set, skipping experiment 2 (key-range sweep)."
    fi

done



# Number of experiments
num_experiments=${#all_configs[@]}
experiment_duration=85 # 85 for Raft, Copilot, Mencius, 180 for MongoDB, 109 for average
total_seconds=$((num_experiments * experiment_duration))
e_hours=$((total_seconds / 3600))
e_minutes=$(( (total_seconds % 3600) / 60))
e_seconds=$((total_seconds % 60))
echo "Number of experiments: $num_experiments"
echo "Estimated running time: ${e_hours}h ${e_minutes}m ${e_seconds}s"

# --- Dry-run mode: print experiment matrix and exit ---
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "=== DRY RUN: Experiment Matrix ==="
    echo "Environment:  $environment"
    echo "Username:     $SERVER_USERNAME"
    echo "Repo dir:     $repo_dir"
    echo "Servers:      ${#servers[@]} (${servers[*]})"
    echo "Build mode:   ${BUILD_ARG:-none}"
    echo "Timeout:      ${TIMEOUT_SEC}s per run"
    echo ""
    echo "--- All ${num_experiments} configs (site,protocol,workload,concurrency,fastpath_mode,ycsb) ---"
    for item in "${all_configs[@]}"; do
        echo "  $item"
    done
    echo ""
    echo "--- Sample deptran_server command ---"
    IFS=',' read -r site protocol workload concurrent fastpath_mode ycsb <<< "${all_configs[0]}"
    echo "  $(build_deptran_cmd "$repo_dir" "$protocol" "$site" "$workload" "$concurrent" "$fastpath_mode" "30" "$ycsb" "")"
    echo "=== END DRY RUN ==="
    exit 0
fi

SECONDS=0
num_experiments_really_run=0

# Execute experiments
while [ ${#all_configs[@]} -gt 0 ]; do
    left=${#all_configs[@]}
    for item in "${all_configs[@]}"; do
        IFS=',' read -r site protocol workload concurrent fastpath_mode ycsb <<< "$item"
        execute_command "${site}" "${protocol}" "${workload}" "${concurrent}" "${fastpath_mode}" "${ycsb}"
        num_experiments_really_run=$((num_experiments_really_run + 1))
        let left-=1
        echo "Left experiments for this loop: ${left} | Todo configs: ${#todo_configs[@]} | Progress (${num_experiments_really_run}/${num_experiments})"
    done
    all_configs=("${todo_configs[@]}")
    todo_configs=()
done

# Report elapsed time
r_hours=$((SECONDS / 3600))
r_minutes=$(( (SECONDS % 3600) / 60 ))
r_seconds=$((SECONDS % 60))
echo "Number of experiments: $num_experiments"
echo "Estimated running time: ${e_hours}h ${e_minutes}m ${e_seconds}s"
printf "The script ran for %d hours, %d minutes, and %d seconds.\n" $r_hours $r_minutes $r_seconds

# Calculate percentage difference
difference=$((num_experiments_really_run - num_experiments))
percentage=$(echo "scale=2; 100 * $difference / $num_experiments" | bc)
echo "The number of experiments really run is ${percentage}% larger than the number of experiments planned."
