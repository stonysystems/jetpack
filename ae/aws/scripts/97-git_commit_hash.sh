#!/bin/bash

# Check if setup.json exists and read values from it
if [ -f "setup.json" ]; then
    SERVER_USERNAME=$(jq -r '.server_username' setup.json)
    environment=$(jq -r '.environment' setup.json)
    if [ "$environment" == "zoo" ]; then
        repo_dir=$(jq -r '.zoo_directory' setup.json)
    else
        repo_dir="/home/ubuntu/code/JetPack"
    fi
    SERVER_0_IP=$(jq -r '.servers[0]["server_0_ip"]' setup.json)
else
    echo "setup.json not found. Exiting."
    exit 1
fi

# Command to retrieve the latest commit hash from the remote repo_dir
get_commit_hash_cmd="cd $repo_dir && git rev-parse HEAD"

# SSH into the remote machine and execute the command
echo "Fetching the latest commit hash from ${SERVER_0_IP} in the repository located at ${repo_dir}..."
latest_commit_hash=$(ssh "${SERVER_USERNAME}@${SERVER_0_IP}" "$get_commit_hash_cmd")

# Output the latest commit hash
if [ -n "$latest_commit_hash" ]; then
    echo "Latest commit hash: $latest_commit_hash"
else
    echo "Failed to retrieve the latest commit hash."
fi

