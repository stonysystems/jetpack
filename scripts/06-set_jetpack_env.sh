#!/bin/bash

# Check if setup.json exists and read values from it
if [ -f "setup.json" ]; then
    experiment_env=$(jq -r '.environment' setup.json)
    N_SERVER=$(jq -r '.n_server' setup.json)
    zoo_directory=$(jq -r '.zoo_directory' setup.json)  # Read zoo_directory from setup.json
else
    echo "setup.json not found. Try to run \`source 00-ips.sh\`. Exiting."
    exit 1
fi

# Set SERVER_USERNAME to "ubuntu" for both AWS and Zoo environments
SERVER_USERNAME="ubuntu"

# Function to handle zoo directory
handle_zoo_directory() {
    if [ "$zoo_directory" != "null" ] && [ -n "$zoo_directory" ]; then
        echo "Using zoo directory from setup.json: $zoo_directory"
    else
        # Ask for the zoo directory if it's not found in setup.json
        echo "Please enter the directory for the experiment on Zoo (e.g., /home/users/ztang/janus):"
        read -r zoo_directory
        # Update setup.json with the new zoo_directory
        jq --arg zoo_directory "$zoo_directory" '.zoo_directory = $zoo_directory' setup.json > tmp.json && mv tmp.json setup.json
        echo "Zoo directory saved to setup.json."
    fi
    # Set the repo_directory to zoo_directory
    repo_directory="$zoo_directory"
}

# Determine environment based on setup.json
if [ "$experiment_env" == "zoo" ]; then
    # Handle Zoo-specific settings
    echo "Zoo environment detected."
    handle_zoo_directory
    commands="sudo $repo_directory/dep.sh"
else
    # Default to AWS settings
    echo "AWS environment detected."
    repo_directory="/home/${SERVER_USERNAME}/code/JetPack"
    commands="cd $repo_directory && ./dep.sh"
    echo "Using default AWS directory: $repo_directory"
fi

# Define an array of server IP addresses dynamically from setup.json
declare -a servers
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)

    # Check if the server IP exists in the JSON file
    if [ "$server_ip" != "null" ] && [ -n "$server_ip" ]; then
        servers+=("${server_ip}")
    else
        echo "Error: IP for server $i is not set or empty in setup.json."
        exit 1
    fi
done

# Debug: Print the servers array to ensure it's populated correctly
echo "Servers array: ${servers[@]}"

# Declare an array to track background job IDs
declare -a jobs

# Iterate through the list of server IPs and execute the command in parallel
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip="${servers[$i]}"

    # Displaying which server is currently being accessed
    echo "Accessing $server_ip ..."

    # SSH into each server and execute the commands in the background
    ssh "${SERVER_USERNAME}@${server_ip}" "$commands" &

    # Save the PID of the background process
    jobs+=($!)
done

# Wait for all background jobs to complete
for job in "${jobs[@]}"; do
    wait $job
done

echo "Commands executed on all servers."

