#!/bin/bash

# Check for setup.json
if [ ! -f setup.json ]; then
    echo "setup.json not found. Exiting."
    exit 1
fi

# Read environment and number of servers
environment=$(jq -r '.environment' setup.json)
N_SERVER=$(jq -r '.n_server' setup.json)

# Verify N_SERVER is 10
if [ "$N_SERVER" -ne 10 ]; then
    echo "Error: Expected N_SERVER=10, but got $N_SERVER. Exiting."
    exit 1
fi

# Optional: skip in 'zoo' env
if [ "$environment" == "zoo" ]; then
    echo "Zoo environment detected. Skipping restart."
    exit 0
fi

# Load server IPs
declare -a servers
for i in $(seq 0 $((N_SERVER - 1))); do
    ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
    if [[ -z "$ip" || "$ip" == "null" ]]; then
        echo "Error: IP for server $i is not set. Exiting."
        exit 1
    fi
    servers+=("$ip")
done

# 1) Restart on server 0, wait for it to finish
echo "Restarting mongod on server 0 (${servers[0]})..."
ssh ubuntu@"${servers[0]}" "sudo systemctl restart mongod && echo 'mongod restarted on ${servers[0]}'"
if [ $? -ne 0 ]; then
    echo "Error: failed to restart mongod on server 0. Exiting."
    exit 1
fi

# 2) Now restart on servers 1–4 in parallel
declare -a jobs
for idx in {1..4}; do
    ip=${servers[idx]}
    (
        echo "Restarting mongod on server $idx ($ip)..."
        ssh ubuntu@"$ip" "sudo systemctl restart mongod && echo 'mongod restarted on $ip'"
    ) &
    jobs+=($!)
done

# Wait for all to finish
for job in "${jobs[@]}"; do
    wait $job
done

echo "Done restarting mongod on servers 0–4."
