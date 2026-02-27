#!/bin/bash

# Check if setup.json exists and read values from it
if [ -f "setup.json" ]; then
    environment=$(jq -r '.environment' setup.json)
    N_SERVER=$(jq -r '.n_server' setup.json)
else
    echo "setup.json not found. Try to run \`source 00-ips.sh\`. Exiting."
    exit 1
fi

if [ "$environment" != "aws" ]; then
    echo "Environment is '$environment', this script is intended for aws only. Exiting."
    exit 0
fi

echo "Checking NTP/chrony status on $N_SERVER AWS servers..."

# Collect all server IPs from setup.json: servers[0].server_0_ip, servers[1].server_1_ip, ...
server_ips=()
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)

    if [ "$server_ip" != "null" ] && [ -n "$server_ip" ]; then
        server_ips+=("$server_ip")
    else
        echo "Error: IP for server $i is not set or empty in setup.json."
        exit 1
    fi
done

for ip in "${server_ips[@]}"; do
    echo "===== $ip ====="
    ssh -o BatchMode=yes -o ConnectTimeout=5 "ubuntu@$ip" '
        echo "Host: $(hostname -s)"
        timedatectl | grep "System clock"
        echo "--- chronyc tracking ---"
        chronyc tracking | egrep "System time|Last offset|RMS offset"
    '
    echo
done

echo "Done checking NTP/chrony on all AWS servers."
