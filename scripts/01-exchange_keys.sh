#!/bin/bash

# Check if setup.json exists and read values from it
if [ -f "setup.json" ]; then
    experiment_env=$(jq -r '.environment' setup.json)
    SERVER_USERNAME=$(jq -r '.server_username' setup.json)
    N_SERVER=$(jq -r '.n_server' setup.json)
else
    echo "setup.json not found. Please make sure setup.json exists and contains the required values. You may fix this by running \`source 00-ips.sh\`."
    exit 1
fi

declare -a servers=()
declare -a server_key=()
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
    server_key=$(jq -r ".servers[$i].server_${i}_key" setup.json)
    servers+=("$server_ip")
done

# Check if the experiment is on AWS or Zoo
if [ "$experiment_env" == "aws" ]; then
    # For AWS: Ensure all server keys are available in setup.json
    echo "Ensure all SERVER keys are available in setup.json. Press Enter to continue."
    read -p "Press Enter to continue..."

    # Refresh local known_hosts entries for all AWS servers
    echo "Refreshing ~/.ssh/known_hosts entries for AWS servers..."
    for server in "${servers[@]}"; do
        # Remove any old (stale) host key entries for this IP
        ssh-keygen -R "$server" >/dev/null 2>&1 || true

        # Add the current host key
        if ssh-keyscan -H "$server" >> ~/.ssh/known_hosts 2>/dev/null; then
            echo "Updated host key for ${server} in ~/.ssh/known_hosts."
        else
            echo "Warning: ssh-keyscan failed for ${server} (server might not be up yet)."
        fi
    done

    # Create a directory to store keys if it doesn't already exist
    mkdir -p aws_keys

    # Define an array for job tracking
    declare -a jobs

    # First loop: Collect public keys from remote servers
    for i in $(seq 0 $((N_SERVER - 1))); do
        # Extract IP and key from setup.json using jq
        server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
        server_key=$(jq -r ".servers[$i].server_${i}_key" setup.json)
        server="server-$i"  # Assuming server hostnames are indexed similarly

        # Log: Check if the server already has an SSH key
        echo "Checking if ${server} (${server_ip}) already has an SSH key..."

        # Check if the server already has an SSH key, if not, generate one
        ssh -i "${server_key}" "${SERVER_USERNAME}@${server_ip}" 'if [ -f ~/.ssh/id_rsa.pub ]; then echo "SSH key exists."; else echo "SSH key does not exist, generating one..."; ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa; fi' >/dev/null 2>&1

        # Display message about collecting public key from each server
        echo "Collecting public key from ${server} (${server_ip})"

        # Copy the public key from each server to the local directory, in the background
        scp -i "${server_key}" "${SERVER_USERNAME}@${server_ip}:~/.ssh/id_rsa.pub" "aws_keys/${server}_id_rsa.pub" &
        # Store job ID
        jobs+=($!)
    done

    # Wait for all SCP jobs to complete
    for job in "${jobs[@]}"; do
        wait $job
    done
    echo "All keys have been collected."

    # Clear job array for next operations
    jobs=()

    # Distribute each public key to every server's authorized_keys, in parallel
    for i in $(seq 0 $((N_SERVER - 1))); do
        (
            # Extract IP and key from setup.json using jq
            server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
            server_key=$(jq -r ".servers[$i].server_${i}_key" setup.json)
            server="server-$i"

            # Distribute keys
            for key_file in aws_keys/*_id_rsa.pub; do
                cat "$key_file" | ssh -i "${server_key}" "${SERVER_USERNAME}@${server_ip}" 'cat >> ~/.ssh/authorized_keys'
            done

            # Also add local public key to each server's authorized_keys
            cat ~/.ssh/id_rsa.pub | ssh -i "${server_key}" "${SERVER_USERNAME}@${server_ip}" 'cat >> ~/.ssh/authorized_keys'

            # Confirmation message
            echo "Updated authorized_keys on ${server} (${server_ip})"
        ) &
        # Store job ID
        jobs+=($!)
    done

    # Wait for all SSH jobs to complete
    for job in "${jobs[@]}"; do
        wait $job
    done

    echo "Public keys distributed and local key added to all servers."

    # Cleanup: Remove the aws_keys directory after use
    rm -rf aws_keys
    echo "Removed aws_keys directory after use."

    # Update aws_key_distributed to true in setup.json
    echo "Updating aws_key_distributed to true in setup.json..."
    jq '.aws_key_distributed = true' setup.json > tmp_setup.json && mv tmp_setup.json setup.json

    # Verify the update
    if jq -e '.aws_key_distributed == true' setup.json > /dev/null; then
        echo "Successfully updated aws_key_distributed to true."
    else
        echo "Failed to update aws_key_distributed in setup.json."
        exit 1
    fi

elif [ "$experiment_env" == "zoo" ]; then
    # For Zoo: Skip the SSH key-related steps
    echo "Zoo environment selected. Skipping SSH key generation and distribution steps."
else
    echo "Invalid environment in setup.json. Please enter either 'aws' or 'zoo'."
    exit 1
fi




# # Perform ssh-keyscan to add remote host keys to known_hosts (for both AWS and Zoo)
# echo "Performing ssh-keyscan to add remote host keys to known_hosts..."

# for server in "${servers[@]}"; do
#     ssh-keyscan -H $server >> ~/.ssh/known_hosts
#     echo "Added ${server} to known_hosts."
# done

# # Add local machine's host key to the remote servers' known_hosts
# echo "Adding the local machine's host key to the remote servers' known_hosts..."
# local_host_key=$(ssh-keyscan -H localhost 2>/dev/null)

# for i in $(seq 0 $((N_SERVER - 1))); do
#     # Extract server IP from setup.json
#     server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)

#     echo "$local_host_key" | ssh "${SERVER_USERNAME}@${server_ip}" 'cat >> ~/.ssh/known_hosts'
#     echo "Added local machine's host key to ${server_ip}'s known_hosts."
# done





# === Prime known_hosts for all cluster hosts (no first-time prompts) ===
echo "Priming known_hosts for the whole cluster..."

# 1) Collect current host keys for all hosts we care about
KN_TMP=$(mktemp)
: > "$KN_TMP"

collect_key() {
  local h="$1"
  # Grab all common key types; ignore failures (e.g., host not up yet)
  ssh-keyscan -T 5 -t rsa,ecdsa,ed25519 "$h" >> "$KN_TMP" 2>/dev/null || \
    echo "Warning: ssh-keyscan failed for $h"
}

for h in "${servers[@]}"; do collect_key "$h"; done

# 2) Refresh LOCAL known_hosts
echo "Refreshing local ~/.ssh/known_hosts entries..."
for h in "${servers[@]}"; do ssh-keygen -R "$h" >/dev/null 2>&1 || true; done
cat "$KN_TMP" >> ~/.ssh/known_hosts
chmod 600 ~/.ssh/known_hosts

# 3) Push to REMOTE servers and refresh their known_hosts
echo "Refreshing known_hosts on all remote servers..."
jobs=()
for i in $(seq 0 $((N_SERVER - 1))); do
  server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
  server_key=$(jq -r ".servers[$i].server_${i}_key" setup.json)

  (
    ssh -i "$server_key" "${SERVER_USERNAME}@${server_ip}" '
      mkdir -p ~/.ssh && chmod 700 ~/.ssh
      touch ~/.ssh/known_hosts && chmod 600 ~/.ssh/known_hosts
    ' >/dev/null

    # Remove stale keys for all cluster hosts on the remote
    for h in '"${servers[@]}"'; do
      ssh -i "$server_key" "${SERVER_USERNAME}@${server_ip}" "ssh-keygen -R $h >/dev/null 2>&1 || true"
    done

    # Append the fresh keys
    scp -i "$server_key" "$KN_TMP" "${SERVER_USERNAME}@${server_ip}:~/.ssh/cluster_known_hosts.tmp" >/dev/null
    ssh -i "$server_key" "${SERVER_USERNAME}@${server_ip}" '
      cat ~/.ssh/cluster_known_hosts.tmp >> ~/.ssh/known_hosts && rm ~/.ssh/cluster_known_hosts.tmp
    ' >/dev/null

    echo "Primed known_hosts on ${server_ip}"
  ) &
  jobs+=($!)
done
for j in "${jobs[@]}"; do wait "$j"; done
rm -f "$KN_TMP"
echo "known_hosts primed for all peers."





echo "Process completed."

