#!/bin/bash

# Source centralized experiment definitions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/experiment_defs.sh"

# Function to handle zoo directory from setup.json
handle_zoo_directory() {
    zoo_directory=$(jq -r '.zoo_directory' setup.json)
    if [ "$zoo_directory" != "null" ] && [ -n "$zoo_directory" ]; then
        echo "Using zoo directory from setup.json: $zoo_directory"
    else
        # Ask for the zoo directory if it's not found in setup.json
        echo "Please enter the directory for the experiment on Zoo (e.g., /home/yourname/code/JetPack):"
        read -r zoo_directory
        # Update setup.json with the new zoo_directory
        jq --arg zoo_directory "$zoo_directory" '.zoo_directory = $zoo_directory' setup.json > tmp.json && mv tmp.json setup.json
        echo "Zoo directory saved to setup.json."
    fi
}

# Check if setup.json exists and read values from it
if [ -f "setup.json" ]; then
    experiment_env=$(jq -r '.environment' setup.json)
    SERVER_USERNAME=$(jq -r '.server_username' setup.json)
    N_SERVER=$(jq -r '.n_server' setup.json)
else
    echo "setup.json not found. Please make sure setup.json exists and contains the required values."
    exit 1
fi

# Set repo_directory based on environment
if [ "$experiment_env" == "zoo" ]; then
    # Handle the Zoo directory logic
    handle_zoo_directory
    repo_directory="$zoo_directory"
else
    # Default to AWS settings
    repo_directory="/home/${SERVER_USERNAME}/code/JetPack"
fi

# Server command to be run on each server
server_command="cd $repo_directory && build/deptran_server -f config/none_copilot.yml -f config/client_open.yml -f config/3c1s3r1p.yml -f config/rw_zipf_1.yml -f config/concurrent_100.yml -m 0 -d 30 -P localhost -N test-"

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

# Prepare the output directory
mkdir -p test_output

# Remove old test output files
rm -f test_output/*

# Determine the set of commands based on the first argument to the script
if [[ "$1" == "full" ]]; then
    initial_commands="cd $repo_directory && bin/rpcgen --python --cpp src/deptran/rcc_rpc.rpc && python3 add_virtual.py && python3 waf configure build"
elif [[ "$1" == "build" ]]; then
    initial_commands="cd $repo_directory && python3 waf configure build"
else
    initial_commands="cd $repo_directory"
fi

# Execute initial commands on the first server
echo "Executing initial setup on ${servers[0]}..."
ssh "${SERVER_USERNAME}@${servers[0]}" "cd $repo_directory && mkdir -p results/recent_csv && rm -f results/recent_csv/*"
ssh "${SERVER_USERNAME}@${servers[0]}" "$initial_commands"

declare -a jobs # Array to keep track of background job IDs

# Iterate through the list of server IPs in parallel
for i in "${!servers[@]}"; do
    output_file="test_output/output_${replicanames[$i]}.txt"
    echo "Running server command on ${replicanames[$i]}..."

    # Execute the server command in the background and redirect output to the file in test_output folder
    ssh "${SERVER_USERNAME}@${servers[$i]}" "${server_command}${replicanames[$i]}" > "$output_file" 2>&1 &

    # Save the PID of the background process
    jobs+=($!)
done

# Wait for all background jobs to complete
for job in "${jobs[@]}"; do
    wait $job
    echo "Job $job completed."
done

# Check the execution results for success
for i in "${!servers[@]}"; do
    output_file="test_output/output_${replicanames[$i]}.txt"
    if grep -q "Mid throughput is" "$output_file" && grep -q "Deleted one." "$output_file" && ! grep -q "generic server error" "$output_file"; then
        echo "Success: Execution on ${replicanames[$i]} was successful."
    else
        echo "Failure: Execution on ${replicanames[$i]} encountered errors."
    fi
    echo "Output saved for server ${replicanames[$i]} in $output_file"
done

echo "All server commands executed in parallel."

