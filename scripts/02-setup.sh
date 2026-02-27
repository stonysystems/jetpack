#!/bin/bash

# Check if setup.json exists and read values from it
if [ -f "setup.json" ]; then
    SERVER_USERNAME=$(jq -r '.server_username' setup.json)
    N_SERVER=$(jq -r '.n_server' setup.json)
else
    echo "setup.json not found. Please ensure the file exists and is properly configured."
    exit 1
fi

# Define the path where the script will be stored on the remote server
SCRIPT_PATH="aws_setup_script.sh"

# Arrays to keep track of background job IDs
declare -a scp_jobs
declare -a ssh_jobs

# First loop: Perform all SCP operations
for i in $(seq 0 $((N_SERVER - 1))); do
    # Read the server IP from setup.json using jq
    server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)

    # Check if the server IP exists and is valid
    if [ "$server_ip" != "null" ] && [ -n "$server_ip" ]; then
        # Display deploy message
        echo "Deploying to server ${i} with IP ${server_ip}"

        # Copy the setup script to the remote server in the background
        scp aws_setup_script.sh "${SERVER_USERNAME}@${server_ip}:${SCRIPT_PATH}" &

        # Store the job ID of the background process
        scp_jobs[$i]=$!
    else
        echo "Error: Invalid IP for server $i in setup.json."
        exit 1
    fi
done

# Wait for all SCP jobs to complete
for job in "${scp_jobs[@]}"; do
    wait $job
done

echo "All files have been copied."

# Second loop: Execute the script on each server
for i in $(seq 0 $((N_SERVER - 1))); do
    # Read the server IP from setup.json using jq
    server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)

    # Check if the server IP exists and is valid
    if [ "$server_ip" != "null" ] && [ -n "$server_ip" ]; then
        # Execute the script on the remote server in the background
        echo "Executing script on server ${i} with IP ${server_ip}"
        ssh "${SERVER_USERNAME}@${server_ip}" "bash ${SCRIPT_PATH}" &

        # Store the job ID of the background process
        ssh_jobs[$i]=$!
    else
        echo "Error: Invalid IP for server $i in setup.json."
        exit 1
    fi
done

# Wait for all SSH jobs to complete
for job in "${ssh_jobs[@]}"; do
    wait $job
done

echo "All scripts have been executed."

