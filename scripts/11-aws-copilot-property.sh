#!/bin/bash

# Usage: ./run_experiments.sh [full|build] [none|rule100|rule101|all]
# If first arg is "full" or "build", sets build mode. Second arg selects experiment(s): "none", "rule100", "rule101", or "all" (default all).

# Constants for configuration files and parameters
CONFIG_FILE_1="none_copilot.yml"
CONFIG_FILE_2="client_open.yml"
CONFIG_FILE_3="3c1s3r3p.yml"
CONFIG_FILE_4="rw_zipf_0.yml"
CONFIG_FILE_5="concurrent_1.yml"
CONFIG_MODE="100"
CONFIG_DURATION="30"

AWS_CONFIG_FILE_2="client_open.yml"
AWS_CONFIG_FILE_3="60c1s5r10p.yml"
AWS_CONFIG_FILE_4="rw_zipf_0.yml"
AWS_CONFIG_FILE_5="concurrent_1.yml"
AWS_CONFIG_FILE_6="YCSB_A.yml"

# Parse build mode and experiment selection
build_mode=""
exp_arg="all"
if [[ "$1" == "full" || "$1" == "build" ]]; then
  build_mode="$1"; shift
fi
if [[ "$1" == "none" || "$1" == "rule100" || "$1" == "rule101" || "$1" == "all" ]]; then
  exp_arg="$1"; shift
fi

# Experiment definitions
declare -a exp_names=("none" "rule100" "rule101")
declare -a exp_file1=("none_copilot.yml" "rule_copilot.yml" "rule_copilot.yml")
declare -a exp_modes=("" "100" "101")

# Determine which experiments to run
if [[ "$exp_arg" == "all" ]]; then
  selected_idxs=(0 1 2)
else
  for i in "${!exp_names[@]}"; do
    if [[ "${exp_names[$i]}" == "$exp_arg" ]]; then
      selected_idxs=("$i")
      break
    fi
  done
fi

# Check required setup.json
if [[ ! -f "setup.json" ]]; then
  echo "setup.json not found. Please create it."; exit 1
fi
experiment_env=$(jq -r '.environment' setup.json)
SERVER_USERNAME=$(jq -r '.server_username' setup.json)
N_SERVER=$(jq -r '.n_server' setup.json)
zoo_directory=$(jq -r '.zoo_directory' setup.json)

# Set repository directory
if [[ "$experiment_env" == "zoo" ]]; then
  repo_directory="$zoo_directory"
else
  repo_directory="/home/${SERVER_USERNAME}/code/JetPack"
fi

# Build servers and replicanames arrays
declare -a servers replicanames
for i in $(seq 0 $((N_SERVER-1))); do
  servers+=( "$(jq -r ".servers[$i].server_${i}_ip" setup.json)" )
  replicanames+=( "server${i}" )
done

# Ensure cleanup on exit
trap 'echo "🧹 Cleaning up netem on ${servers[0]}…"; ssh "${SERVER_USERNAME}@${servers[0]}" "sudo tc qdisc del dev ens5 root netem"' EXIT

# Prepare output directory
rm -rf test_output
mkdir -p test_output

# Main experiment loop
for idx in "${selected_idxs[@]}"; do
  AWS_CONFIG_FILE_1="${exp_file1[$idx]}"
  AWS_CONFIG_MODE="${exp_modes[$idx]}"
  exp_name="${exp_names[$idx]}"
  echo "=== Running experiment: $exp_name (file1=$AWS_CONFIG_FILE_1 mode=${AWS_CONFIG_MODE:-none}) ==="

  # Compose server_command for this experiment
  if [[ "$experiment_env" == "zoo" ]]; then
    server_command="cd $repo_directory && build/deptran_server -f config/$CONFIG_FILE_1 -f config/$CONFIG_FILE_2 -f config/$CONFIG_FILE_3 -f config/$CONFIG_FILE_4 -f config/$CONFIG_FILE_5 -m $CONFIG_MODE -d $CONFIG_DURATION"
  else
    server_command="cd $repo_directory && build/deptran_server -f config/$AWS_CONFIG_FILE_1 -f config/$AWS_CONFIG_FILE_2 -f config/$AWS_CONFIG_FILE_3 -f config/$AWS_CONFIG_FILE_4 -f config/$AWS_CONFIG_FILE_5 -f config/$AWS_CONFIG_FILE_6 -m $AWS_CONFIG_MODE -d $CONFIG_DURATION"
  fi

  # Determine initial commands
  if [[ "$build_mode" == "full" ]]; then
    initial_commands="cd $repo_directory && bin/rpcgen --python --cpp src/deptran/rcc_rpc.rpc && python3 add_virtual.py && python3 waf configure build"
  elif [[ "$build_mode" == "build" ]]; then
    initial_commands="cd $repo_directory && python3 waf configure build"
  else
    initial_commands="cd $repo_directory"
  fi

  # Execute initial setup on server0
  ssh "${SERVER_USERNAME}@${servers[0]}" "cd $repo_directory && mkdir -p results/recent_csv && rm -f results/recent_csv/*"
  ssh "${SERVER_USERNAME}@${servers[0]}" "$initial_commands"

  # Run servers in parallel
declare -a jobs
  for i in "${!servers[@]}"; do
    out="test_output/test-${replicanames[$i]}.txt"
    ssh "${SERVER_USERNAME}@${servers[$i]}" "$server_command -P ${replicanames[$i]} -N test-${replicanames[$i]}" >"$out" 2>&1 &
    jobs+=( $! )
  done

  # Inject netem after 42s
  (sleep 42 && ssh "${SERVER_USERNAME}@${servers[0]}" "sudo tc qdisc add dev ens5 root netem delay 300ms") &

  # Wait for servers to finish
  for pid in "${jobs[@]}"; do wait $pid; done

  # Fetch CSVs in parallel
declare -a scp_pids
  for i in "${!servers[@]}"; do
    remote_csv="$repo_directory/results/recent_csv/test-${replicanames[$i]}.csv"
    local_csv="test_output/test-${replicanames[$i]}.csv"
    scp "${SERVER_USERNAME}@${servers[$i]}:$remote_csv" "$local_csv" &
    scp_pids+=( $! )
  done
  for pid in "${scp_pids[@]}"; do wait $pid; done

  # Rename files for this experiment
  stem=$(basename "$AWS_CONFIG_FILE_1" .yml)
  if [[ "$stem" == "none_copilot" ]]; then prop="copilot-property-$stem"
  else prop="copilot-property-$stem-$AWS_CONFIG_MODE"; fi

  for ext in csv txt; do
    for src in test_output/test-server*.${ext}; do
      [[ -e "$src" ]] || continue
      srv=$(basename "$src" .${ext} | cut -d- -f2)
      if [[ "$ext" == "txt" ]]; then out_ext="res"; else out_ext="$ext"; fi
      mv "$src" "test_output/${prop}-${srv}.${out_ext}"
    done
  done

done

echo "✅ All experiments completed."
