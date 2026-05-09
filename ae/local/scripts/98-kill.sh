#!/bin/bash

# Load the JSON configuration
CONFIG_FILE="setup.json"

if ! [ -f "$CONFIG_FILE" ]; then
    echo "Configuration file $CONFIG_FILE not found."
    exit 1
fi

# Parse JSON configuration
environment=$(jq -r '.environment' "$CONFIG_FILE")
n_server=$(jq -r '.n_server' "$CONFIG_FILE")
servers=$(jq -c '.servers' "$CONFIG_FILE")
server_username=$(jq -r '.zoo_username' "$CONFIG_FILE")

# Check if we are running in the 'zoo' environment
if [ "$environment" != "zoo" ]; then
    server_username=$(jq -r '.server_username' "$CONFIG_FILE")
fi

# Declare arrays to track background job information
declare -a jobs
declare -a job_names

# Process the servers
for ((i=0; i<n_server; i++)); do
    server_ip=$(echo "$servers" | jq -r --argjson i "$i" '.[$i]["server_" + ($i|tostring) + "_ip"]')
    if [ "$server_ip" == "null" ]; then
        echo "No IP found for server $i in configuration. Skipping."
        continue
    fi
    replica_name="server_$i"
    echo "Initiating 'pkill -9 -f deptran' on server: $replica_name"

    # Run the command on the remote server in the background
    ssh "$server_username"@"$server_ip" "pkill -9 -f deptran" &> /dev/null &

    # Save the PID of the background process
    jobs+=($!)
    job_names+=("$replica_name")
done

# Wait for all background jobs to complete and check their exit status
for j in "${!jobs[@]}"; do
    job=${jobs[$j]}
    replica_name=${job_names[$j]}

    wait $job
    exit_status=$?

    if [ $exit_status -eq 0 ]; then
        echo "Successfully killed processes on $replica_name"
    else
        echo "Failed to execute pkill on $replica_name"
    fi
done

echo "Operation completed on all servers."

