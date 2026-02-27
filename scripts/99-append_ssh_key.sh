#!/bin/bash

# --- Pre-flight Checks ---

# 1. Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: The 'jq' command is not found. Please install jq to run this script."
    echo "On Debian/Ubuntu: sudo apt-get install jq"
    echo "On macOS: brew install jq"
    exit 1
fi

# 2. Check if setup.json exists
SETUP_FILE="setup.json"
if [ ! -f "$SETUP_FILE" ]; then
    echo "Error: Configuration file '$SETUP_FILE' not found in the current directory."
    exit 1
fi

# --- User Input ---

# Prompt for the SSH public key
read -p "Enter the SSH public key you want to distribute: " public_key

# Check if the public key was entered
if [[ -z "$public_key" ]]; then
    echo "No public key entered. Exiting."
    exit 1
fi

# --- Configuration Loading ---

echo "Reading configuration from $SETUP_FILE..."
# Read the username and number of servers from setup.json
SERVER_USERNAME=$(jq -r '.server_username' "$SETUP_FILE")
N_SERVER=$(jq -r '.n_server' "$SETUP_FILE")

# Validate that the keys were found in the JSON file
if [[ "$SERVER_USERNAME" == "null" || "$N_SERVER" == "null" ]]; then
    echo "Error: '.server_username' or '.n_server' could not be found in $SETUP_FILE."
    exit 1
fi

# Dynamically define the list of server IP addresses from setup.json
declare -a servers
echo "Found $N_SERVER servers in configuration. Populating server list..."
for i in $(seq 0 $((N_SERVER - 1))); do
    # Extract IP from the .servers array using jq
    server_ip=$(jq -r ".servers[$i].server_${i}_ip" "$SETUP_FILE")
    
    if [[ "$server_ip" != "null" && -n "$server_ip" ]]; then
        servers+=("$server_ip")
    else
        echo "Warning: Could not find IP for server index $i in $SETUP_FILE. Skipping."
    fi
done

if [ ${#servers[@]} -eq 0 ]; then
    echo "Error: No server IPs were successfully loaded from the configuration. Exiting."
    exit 1
fi

# --- Parallel Execution ---

# Arrays to keep track of background job PIDs and map them to server IPs for better reporting
declare -a pids
declare -A pid_to_server_map

echo "--------------------"
echo "Distributing key to ${#servers[@]} servers in parallel..."

# Loop through each server and append the public key to the authorized_keys in parallel
for server_ip in "${servers[@]}"; do
    echo "-> Sending key to $server_ip"
    
    # This command is more robust: it ensures the .ssh directory exists and has the correct permissions.
    # It also sets permissions for the authorized_keys file itself.
    ssh_command="mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$public_key' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    
    # Execute in the background. Using -o options for non-interactive and faster connections.
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$SERVER_USERNAME@$server_ip" "$ssh_command" &
    
    # Store the PID of the background job
    pid=$!
    pids+=($pid)
    pid_to_server_map[$pid]=$server_ip
done

# --- Wait for Completion & Report Status ---

echo "Waiting for all distribution jobs to complete..."
error_count=0
for pid in "${pids[@]}"; do
    # Wait for the specific job to finish
    if wait $pid; then
        # The job finished with exit code 0 (success)
        echo "✅ Success: Key distributed to ${pid_to_server_map[$pid]}."
    else
        # The job finished with a non-zero exit code (failure)
        echo "❌ Failure: Could not distribute key to ${pid_to_server_map[$pid]}."
        ((error_count++))
    fi
done

echo "--------------------"
echo "Process completed."
if [ $error_count -gt 0 ]; then
    echo "$error_count servers failed. Please check the output above for details."
    exit 1
else
    echo "All keys distributed successfully."
fi