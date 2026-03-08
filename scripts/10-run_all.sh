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

# Experiment configs
declare -a jetpack_protocols=(
	"rule_fpga_raft"
	"rule_copilot"
	"rule_mencius"
	"rule_mongodb"
)
declare -a sites=(
	"60c1s5r10p"
)
declare -a origin_protocols=(
	"none_raft"
	"none_copilot"
	"none_mencius"
	"none_mongodb"
)
declare -a workloads=(
	"rw_1000000"
	# "rw_zipf_1"
	# "rw_zipf_0.9"
	# "rw_zipf_0.4"
)
declare -a ycsbs=(
    "YCSB_A"
    # "YCSB_B"
)
declare -a zipf_workloads=(
    "rw_zipf_1"
    "rw_zipf_0.95"
    "rw_zipf_0.9"
    "rw_zipf_0.85"
    "rw_zipf_0.8"
    "rw_zipf_0.75"
    "rw_zipf_0.7"
    "rw_zipf_0.65"
    "rw_zipf_0.6"
    "rw_zipf_0.55"
    "rw_zipf_0.5"
    # "rw_zipf_0.4"
    # "rw_zipf_0.3"
    # "rw_zipf_0.2"
    # "rw_zipf_0.1"
    # "rw_zipf_0"
)
declare -a key_range_workloads=(
    "rw_1"
    "rw_10"
    "rw_100"
    "rw_1000"
    "rw_10000"
    "rw_100000"
    "rw_1000000"
)
declare -a raft_concs=(
    "concurrent_1"
    "concurrent_10"
    "concurrent_20"
    # "concurrent_30"
    "concurrent_40"
    # "concurrent_50"
    # # "concurrent_55"
    "concurrent_60"
    # # "concurrent_65"
    # "concurrent_70"
    # # "concurrent_75"
    "concurrent_80"
    # # "concurrent_85"
    # "concurrent_90"
    # # "concurrent_95"
    "concurrent_100"
    # "concurrent_110"
    "concurrent_120"
    # "concurrent_130"
    "concurrent_140"
    "concurrent_150"
    "concurrent_160"
    "concurrent_170"
    "concurrent_180"
    "concurrent_190"
    "concurrent_200"
    # "concurrent_225"
    "concurrent_250"
    # "concurrent_275"
    "concurrent_300"
    "concurrent_400"
    "concurrent_500"
    "concurrent_750"
    "concurrent_1000"
)
declare -a copilot_concs=(
    "concurrent_1"
    # "concurrent_5"
    "concurrent_10"
    "concurrent_20"
    "concurrent_30"
    "concurrent_40"
    "concurrent_50"
    # "concurrent_55"
    "concurrent_60"
    # "concurrent_65"
    "concurrent_70"
    "concurrent_72"
    "concurrent_75"
    "concurrent_77"
    "concurrent_80"
    "concurrent_82"
    "concurrent_85"
    "concurrent_87"
    "concurrent_90"
    # "concurrent_95"
    "concurrent_100"
    # "concurrent_110"
    "concurrent_120"
    # "concurrent_130"
    "concurrent_140"
    # "concurrent_150"
    "concurrent_160"
    # "concurrent_170"
    "concurrent_180"
    # "concurrent_190"
    "concurrent_200"
)
declare -a mencius_concs=(
    "concurrent_1"
    # "concurrent_5"
    "concurrent_10"
    # "concurrent_11"
    "concurrent_12"
    # "concurrent_13"
    "concurrent_14"
    # "concurrent_15"
    "concurrent_16"
    # "concurrent_17"
    "concurrent_18"
    # "concurrent_19"
    "concurrent_20"
    "concurrent_25"
    "concurrent_30"
    "concurrent_35"
    "concurrent_40"
    "concurrent_45"
    "concurrent_50"
    "concurrent_55"
    "concurrent_60"
)
declare -a mongodb_concs=(
    "concurrent_1"
    # "concurrent_5"
    "concurrent_10"
    "concurrent_20"
    "concurrent_30"
    "concurrent_35"
    # "concurrent_37"
    "concurrent_40"
    # "concurrent_45"
    "concurrent_50"
    "concurrent_60"
    # "concurrent_65"
    "concurrent_70"
    # "concurrent_75"
    "concurrent_80"
    # "concurrent_85"
    "concurrent_90"
    # "concurrent_95"
    "concurrent_100"
    "concurrent_110"
    "concurrent_120"
)
declare -a concurrents=(
    "raft_concs"
    "copilot_concs"
    "mencius_concs"
    "mongodb_concs"
)
declare -a fixed_concurrents=(
    "concurrent_150"
    "concurrent_50"
    "concurrent_16"
    "concurrent_40"
)
declare -a fastpath_modes=(
	"0"
	# "25"
	# "50"
	# "75"
	"100"
    "101"
)


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

    # Construct the directory path
    exp_dir="results/${current_time}-${latest_commit_hash}"
    mkdir -p "$exp_dir"
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

    exp_name="${protocol}-${site}-${workload}-${concurrent}-${fastpath_mode}-${ycsb}"
    client_config="client_open.yml"
    if [[ "$protocol" == *_* ]]; then
        proto_suffix="${protocol#*_}"
        if [ -n "$proto_suffix" ]; then
            client_config="client_open_${proto_suffix}.yml"
        fi
    fi
    server_command="cd ${repo_dir} && build/deptran_server -f config/${client_config} -f config/${protocol}.yml -f config/${site}.yml -f config/${workload}.yml -f config/${concurrent}.yml  -f config/${ycsb}.yml  -d 30 -m ${fastpath_mode}"

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

    # experiment1: 4 protocols * (1 original + 2 ycsb * 16 workloads * 3 fastpath rate * 1 conc)
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

    # experiment2: 4 protocols * (1 original + 2 ycsb * 7 workloads * 3 fastpath rate * 1 conc)
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
    client_config="client_open.yml"
    if [[ "$protocol" == *_* ]]; then
        proto_suffix="${protocol#*_}"
        if [ -n "$proto_suffix" ]; then
            client_config="client_open_${proto_suffix}.yml"
        fi
    fi
    echo "  cd ${repo_dir} && build/deptran_server -f config/${client_config} -f config/${protocol}.yml -f config/${site}.yml -f config/${workload}.yml -f config/${concurrent}.yml -f config/${ycsb}.yml -d 30 -m ${fastpath_mode}"
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
