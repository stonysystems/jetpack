#!/bin/bash

# Source centralized experiment definitions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/experiment_defs.sh"

# Constants for configuration files and parameters
# These override the centralized defaults for this single-experiment runner.
CONFIG_FILE_1="rule_mongodb.yml"
CONFIG_FILE_2="client_open.yml"
CONFIG_FILE_3="mongodb_5r_local.yml"
CONFIG_FILE_4="rw_zipf_0.yml"
CONFIG_FILE_5="concurrent_2.yml"
CONFIG_MODE="100"
CONFIG_DURATION="30"

AWS_CONFIG_FILE_1="rule_copilot.yml"
AWS_CONFIG_FILE_2="client_open.yml"  # Added client_closed.yml for AWS
AWS_CONFIG_FILE_3="60c1s5r10p.yml"
AWS_CONFIG_FILE_4="rw_1000000.yml"
AWS_CONFIG_FILE_5="concurrent_100.yml"
AWS_CONFIG_MODE="101"  # Added -m value for AWS

# AWS_CONFIG_FILE_1="rule_raft.yml"
# AWS_CONFIG_FILE_2="client_open_failure_recovery.yml"  # Added client_closed.yml for AWS
# AWS_CONFIG_FILE_3="30c1s5r10p.yml"
# AWS_CONFIG_FILE_4="rw_1000000.yml"
# AWS_CONFIG_FILE_5="concurrent_60.yml"
# AWS_CONFIG_MODE="101"  # Added -m value for AWS

# Parse CLI arguments for build mode and optional failover test
usage() {
    echo "Usage: $0 [full|build] [--failover] [--filename <name>] [--dry-run]"
    echo ""
    echo "Options:"
    echo "  full          Regenerate RPC + build before running"
    echo "  build         Build before running"
    echo "  --failover|-F Enable failure recovery mode (duration=70s)"
    echo "  --filename|-o Set custom result filename prefix"
    echo "  --dry-run|-n  Print commands without executing them"
}

FAILOVER_TEST=false
BUILD_MODE=""
CUSTOM_FILENAME=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        full|build)
            BUILD_MODE="$1"
            ;;
        --failover|-F)
            FAILOVER_TEST=true
            ;;
        --filename|-o)
            if [[ -n "$2" && "$2" != -* ]]; then
                CUSTOM_FILENAME="$2"
                shift
            else
                echo "Error: --filename requires a value."
                usage
                exit 1
            fi
            ;;
        --dry-run|-n)
            DRY_RUN=true
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

# Adjust duration based on failover mode
if [ "$FAILOVER_TEST" = true ]; then
    CONFIG_DURATION="70"
else
    CONFIG_DURATION="30"
fi

# Check if setup.json exists and read values from it
if [ -f "setup.json" ]; then
    experiment_env=$(jq -r '.environment' setup.json)
    SERVER_USERNAME=$(jq -r '.server_username' setup.json)
    N_SERVER=$(jq -r '.n_server' setup.json)
    zoo_directory=$(jq -r '.zoo_directory' setup.json)
else
    echo "setup.json not found. Please make sure setup.json exists and contains the required values."
    exit 1
fi

# Set repo_directory based on environment
if [ "$experiment_env" == "zoo" ]; then
    repo_directory="$zoo_directory"
else
    repo_directory="/home/${SERVER_USERNAME}/code/JetPack"
fi

# Set server_command based on environment (AWS or Zoo)
# Uses derive_client_config() from experiment_defs.sh for AWS client config derivation.
if [ "$experiment_env" == "zoo" ]; then
    # Zoo-specific command (fixed config files, not matrix-driven)
    server_command="cd $repo_directory && build/deptran_server -f config/$CONFIG_FILE_1 -f config/$CONFIG_FILE_2 -f config/$CONFIG_FILE_3 -f config/$CONFIG_FILE_4 -f config/$CONFIG_FILE_5 -m $CONFIG_MODE -d $CONFIG_DURATION"
    if [ "$FAILOVER_TEST" = true ]; then
        server_command+=" -f config/failover.yml"
    fi
else
    # AWS-specific command
    if [ "$FAILOVER_TEST" = true ]; then
        effective_aws_config_file_2="client_open_failure_recovery.yml"
    else
        # Use centralized helper from experiment_defs.sh
        effective_aws_config_file_2=$(derive_client_config "${AWS_CONFIG_FILE_1%.yml}")
    fi
    server_command="cd $repo_directory && build/deptran_server -f config/$AWS_CONFIG_FILE_1 -f config/$effective_aws_config_file_2 -f config/$AWS_CONFIG_FILE_3 -f config/$AWS_CONFIG_FILE_4 -f config/$AWS_CONFIG_FILE_5"
    if [ "$FAILOVER_TEST" = true ]; then
        server_command+=" -f config/failover.yml"
    fi
    server_command+=" -m $AWS_CONFIG_MODE -d $CONFIG_DURATION"
fi

# Default result prefix (matches refresh_prefixes format)
DEFAULT_RESULT_PREFIX="${AWS_CONFIG_FILE_1%.yml}-${AWS_CONFIG_FILE_3%.yml}-${AWS_CONFIG_FILE_4%.yml}-${AWS_CONFIG_FILE_5%.yml}-${AWS_CONFIG_MODE}-YCSB_A"

# Print server command for debugging
echo "Server Command: $server_command"

# Define arrays for server IP addresses and replica names dynamically based on setup.json
declare -a servers
declare -a replicanames

# Populate servers and replicanames based on N_SERVER from setup.json
for i in $(seq 0 $((N_SERVER - 1))); do
    # Extract IP from setup.json using jq
    server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
    name_var="server${i}"

    servers+=("$server_ip")
    replicanames+=($name_var)
done

# --- Dry-run mode: print generated commands and exit ---
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "=== DRY RUN ==="
    echo "Environment:  $experiment_env"
    echo "Username:     $SERVER_USERNAME"
    echo "Repo dir:     $repo_directory"
    echo "Build mode:   ${BUILD_MODE:-none}"
    echo "Failover:     $FAILOVER_TEST"
    echo "Duration:     ${CONFIG_DURATION}s"
    echo "Timeout:      180s"
    echo "Servers:      ${#servers[@]}"
    echo ""

    # Build command
    if [[ "$BUILD_MODE" == "full" ]]; then
        build_cmd="cd $repo_directory && bin/rpcgen --python --cpp src/deptran/rcc_rpc.rpc && python3 add_virtual.py && python3 waf configure build"
    elif [[ "$BUILD_MODE" == "build" ]]; then
        build_cmd="cd $repo_directory && python3 waf configure build"
    else
        build_cmd="cd $repo_directory"
    fi

    echo "[build] ssh ${SERVER_USERNAME}@${servers[0]} \"cd $repo_directory && mkdir -p results/recent_csv && rm -f results/recent_csv/*\""
    echo "[build] ssh ${SERVER_USERNAME}@${servers[0]} \"$build_cmd\""
    echo ""

    # Per-server run commands
    if [ -n "$CUSTOM_FILENAME" ]; then
        result_base="$CUSTOM_FILENAME"
    elif [ "$FAILOVER_TEST" = true ]; then
        result_base="jetpack-failure-recovery"
    else
        result_base="$DEFAULT_RESULT_PREFIX"
    fi

    for i in "${!servers[@]}"; do
        run_name="${result_base}-${replicanames[$i]}"
        output_file="test_output/${result_base}-${replicanames[$i]}.res"
        echo "[run]   timeout 180s ssh ${SERVER_USERNAME}@${servers[$i]} \"${server_command} -P ${replicanames[$i]} -N ${run_name}\" > $output_file 2>&1 &"
    done

    echo ""
    echo "[pull]  scp ${SERVER_USERNAME}@${servers[0]}:$repo_directory/results/recent_csv/${result_base}-server*.csv test_output/"
    echo "=== END DRY RUN ==="
    exit 0
fi

# We assume scp_jm_file.sh is in the JetPack repo root on all servers
SCP_MONITOR_SCRIPT="$repo_directory/scp_jm_file.sh"

# Paths to clean on remote servers
declare -a cleanup_targets
if [ "$experiment_env" == "zoo" ]; then
  # For Zoo, repo_directory points to JetPack root on that environment
  cleanup_targets=("/tmp/JM_Jetpack_*" "${repo_directory}/tmp/JM_Jetpack_*" "/tmp/.jm_jetpack_seen")
else
  # AWS: keep your old /home/ubuntu/code/tmp path
  cleanup_targets=("/tmp/JM_Jetpack_*" "/home/ubuntu/code/tmp/JM_Jetpack_*" "/tmp/.jm_jetpack_seen")
fi

# cleanup_remote_state() {
#   local ip
#   local pids=()
#   for ip in "${servers[@]}"; do
#     {
#       echo "[$ip] Killing existing JM scp monitors and cleaning state..."

#       # Build the remote command as a single string
#       local remote_cmd="pkill -f 'scp_jm_file.sh' 2>/dev/null || true; rm -f ${cleanup_targets[*]} 2>/dev/null || true"

#       # Echo what we're about to run
#       echo "[$ip] About to run:"
#       echo "ssh ${SERVER_USERNAME}@${ip} \"$remote_cmd\""

#       # Actually run it
#       if ssh "${SERVER_USERNAME}@${ip}" "$remote_cmd"; then
#         echo "[$ip] Cleanup OK"
#       else
#         status=$?
#         echo "[$ip] Cleanup FAILED (ssh exit $status)"
#       fi
#     } &
#     pids+=($!)
#   done

#   for pid in "${pids[@]}"; do
#     wait "$pid"
#   done

#   echo "All remote JM_Jetpack cleanups finished."
# }
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

cleanup_remote_state() {
  echo "Starting parallel JM_Jetpack cleanup on all servers..."
  local ip
  local pids=()

  for ip in "${servers[@]}"; do
    {
      echo "[$ip] Cleanup: killing monitors and removing JM_Jetpack files..."
      # Use [s]cp_jm_file.sh so pkill doesn't kill its own /bin/sh wrapper
      local remote_cmd="pkill -f '[s]cp_jm_file.sh' 2>/dev/null || true; rm -f ${cleanup_targets[*]} 2>/dev/null || true"

      if ssh $SSH_OPTS "${SERVER_USERNAME}@${ip}" "$remote_cmd"; then
        echo "[$ip] Cleanup OK"
      else
        status=$?
        echo "[$ip] Cleanup FAILED (ssh exit $status)"
      fi
    } &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  echo "All remote JM_Jetpack cleanups finished."
}


start_scp_monitors() {
  # For now only run monitors on AWS-style env (your scp_jm_file.sh hard-codes the 10 AWS IPs)
  if [ "$experiment_env" == "zoo" ]; then
    echo "Zoo environment detected; skipping JM scp monitors."
    return
  fi

  local pids=()
  local ip
  for i in "${!servers[@]}"; do
    ip="${servers[$i]}"
    echo "[$ip] Starting JM scp monitor (index $i)..."
    {
      ssh "${SERVER_USERNAME}@${ip}" "
        nohup $SCP_MONITOR_SCRIPT $i ${SERVER_USERNAME} > /tmp/scp_jm_file.log 2>&1 &
      " && echo "[$ip] Monitor started" || echo "[$ip] Failed to start monitor"
    } &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  echo "All JM scp monitors started."
}

# Prepare the output directory
mkdir -p test_output

# Remove old test output files
rm -f test_output/*

# Kill any leftover scp_jm_file.sh monitors and clean JM_Jetpack_* + state before each run
cleanup_remote_state


# Determine the set of commands based on the requested build mode
if [[ "$BUILD_MODE" == "full" ]]; then
    initial_commands="cd $repo_directory && bin/rpcgen --python --cpp src/deptran/rcc_rpc.rpc && python3 add_virtual.py && python3 waf configure build"
elif [[ "$BUILD_MODE" == "build" ]]; then
    initial_commands="cd $repo_directory && python3 waf configure build"
else
    initial_commands="cd $repo_directory"
fi

# Execute initial commands on the first server
echo "Executing initial setup on ${servers[0]} with user ${SERVER_USERNAME}..."
ssh "${SERVER_USERNAME}@${servers[0]}" "cd $repo_directory && mkdir -p results/recent_csv && rm -f results/recent_csv/*"
ssh "${SERVER_USERNAME}@${servers[0]}" "$initial_commands"

# # Start JM_Jetpack scp monitors on all servers before running the experiment
# start_scp_monitors

SECONDS=0

declare -a jobs        # background PIDs
declare -a output_files
declare -a job_names   # optional: map index -> replica name

TIMEOUT=180   # seconds (3 minutes)
timeout_occurred=false

# Iterate through the list of server IPs in parallel
for i in "${!servers[@]}"; do
    if [ -n "$CUSTOM_FILENAME" ]; then
        result_base="$CUSTOM_FILENAME"
    elif [ "$FAILOVER_TEST" = true ]; then
        result_base="jetpack-failure-recovery"
    else
        result_base="$DEFAULT_RESULT_PREFIX"
    fi

    output_file="test_output/${result_base}-${replicanames[$i]}.res"
    run_name="${result_base}-${replicanames[$i]}"

    output_files[$i]="$output_file"
    job_names[$i]="${replicanames[$i]}"
    echo "Running server command on ${replicanames[$i]}..."

    # Run ssh with a 3-minute timeout, in the background
    timeout "${TIMEOUT}s" \
        ssh "${SERVER_USERNAME}@${servers[$i]}" \
            "${server_command} -P ${replicanames[$i]} -N ${run_name}" \
        > "$output_file" 2>&1 &

    jobs[$i]=$!   # save PID at same index as replica/server
done

# Wait for all background jobs to complete (or timeout)
for i in "${!jobs[@]}"; do
    pid=${jobs[$i]}
    if wait "$pid"; then
        echo "Job $pid (${job_names[$i]}) completed successfully."
    else
        status=$?
        if [[ $status -eq 124 ]]; then
            echo "Job $pid (${job_names[$i]}) TIMED OUT after ${TIMEOUT}s."
            timeout_occurred=true
        else
            echo "Job $pid (${job_names[$i]}) FAILED with exit code $status."
        fi
    fi
done

# Pull recent CSV results from the shared results directory (available via NFS)
remote_results_dir="$repo_directory/results/recent_csv"
echo "Pulling recent CSV results from ${servers[0]}..."
result_base="${CUSTOM_FILENAME:-$DEFAULT_RESULT_PREFIX}"
if [ "$FAILOVER_TEST" = true ]; then
    result_base="jetpack-failure-recovery"
fi

# Prefer result_base on remote; fallback to test-server naming if needed
remote_pattern="$remote_results_dir/${result_base}-server*.csv"
fallback_pattern="$remote_results_dir/test-server*.csv"

if ssh "${SERVER_USERNAME}@${servers[0]}" "[ -d '$remote_results_dir' ] && ls $remote_pattern >/dev/null 2>&1"; then
    pattern_to_pull="$remote_pattern"
elif ssh "${SERVER_USERNAME}@${servers[0]}" "[ -d '$remote_results_dir' ] && ls $fallback_pattern >/dev/null 2>&1"; then
    pattern_to_pull="$fallback_pattern"
else
    pattern_to_pull=""
fi
if [ -n "$pattern_to_pull" ]; then
    if scp "${SERVER_USERNAME}@${servers[0]}:$pattern_to_pull" test_output/; then
        echo "Result CSV files copied to test_output/"
        # Normalize filenames locally to result_base
        for csv_file in test_output/*.csv; do
            [ -e "$csv_file" ] || continue
            base_name=$(basename "$csv_file")
            # Accept both test-serverX.csv and <result_base>-serverX.csv
            if [[ "$base_name" == test-server*.csv ]]; then
                server_suffix=${base_name#test-}          # server0.csv
            elif [[ "$base_name" == ${result_base}-server*.csv ]]; then
                server_suffix=${base_name#${result_base}-} # server0.csv
            else
                continue
            fi
            new_name="test_output/${result_base}-${server_suffix}"
            mv "$csv_file" "$new_name"
        done
    else
        echo "Failed to copy result CSV files from ${servers[0]}."
    fi
else
    echo "No result CSV files found at $remote_results_dir on ${servers[0]}."
fi

# Check the execution results for success
for i in "${!servers[@]}"; do
    output_file="${output_files[$i]}"
    if grep -q "Mid throughput is" "$output_file" && ! grep -q "generic server error" "$output_file"; then
        echo "Success: Execution on ${replicanames[$i]} was successful."
    else
        echo "Failure: Execution on ${replicanames[$i]} encountered errors."
    fi
    echo "Output saved for server ${replicanames[$i]} in $output_file"
done

total_time=$SECONDS
echo "All server commands executed in parallel. Total time taken: $total_time seconds."

if [ "$timeout_occurred" = true ]; then
    echo "Timeout detected; invoking 98-kill.sh to clean deptran processes on remote servers."
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    bash "${script_dir}/98-kill.sh"
fi

# Stop scp_jm_file.sh monitors and clean JM_Jetpack_* artifacts + state on all servers.
# cleanup_remote_state
