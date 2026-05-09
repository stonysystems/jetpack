#!/bin/bash
# Bootstrap each AWS instance: scp aws_setup_script.sh and run it remotely
# with the host-specific SERVER_INDEX + SERVER_IPS env vars. After all hosts
# return, bootstrap the MongoDB replica set with server0 as the preferred
# PRIMARY (init_mongodb_replicaset.sh).
#
# Idempotent — re-running on a partially-set-up cluster is safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check if setup.json exists and read values from it
if [ -f "setup.json" ]; then
    SERVER_USERNAME=$(jq -r '.server_username' setup.json)
    N_SERVER=$(jq -r '.n_server' setup.json)
else
    echo "setup.json not found. Please ensure the file exists and is properly configured."
    exit 1
fi

# Build a comma-separated list of all server IPs (read once, reused for
# every host so each one knows the whole cluster's topology).
declare -a IPS
for i in $(seq 0 $((N_SERVER - 1))); do
    ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
    if [[ -z "$ip" || "$ip" == "null" ]]; then
        echo "Error: Invalid IP for server $i in setup.json."
        exit 1
    fi
    IPS+=("$ip")
done
SERVER_IPS_CSV=$(IFS=','; echo "${IPS[*]}")

SCRIPT_PATH="aws_setup_script.sh"
declare -a scp_jobs ssh_jobs

# First loop: SCP the bootstrap script to every host.
for i in $(seq 0 $((N_SERVER - 1))); do
    echo "Deploying to server ${i} with IP ${IPS[$i]}"
    scp aws_setup_script.sh "${SERVER_USERNAME}@${IPS[$i]}:${SCRIPT_PATH}" &
    scp_jobs[$i]=$!
done
for job in "${scp_jobs[@]}"; do
    wait "$job"
done
echo "All files have been copied."

# Second loop: run aws_setup_script.sh on each host in parallel, passing
# SERVER_INDEX, SERVER_IPS, and N_SERVER as env vars so the per-host
# config (mongod, etcd, zookeeper, myid, zoo.cfg, …) gets the right values.
for i in $(seq 0 $((N_SERVER - 1))); do
    echo "Executing setup on server ${i} (${IPS[$i]})"
    ssh "${SERVER_USERNAME}@${IPS[$i]}" \
        "SERVER_INDEX=${i} SERVER_IPS='${SERVER_IPS_CSV}' N_SERVER=${N_SERVER} bash ${SCRIPT_PATH}" &
    ssh_jobs[$i]=$!
done
for job in "${ssh_jobs[@]}"; do
    wait "$job"
done
echo "All bootstrap scripts have been executed."

# After every host has mongod installed + running with replSetName=jetpack-rs,
# initialize the replica set with server0 as the preferred PRIMARY (priority=2.0).
# This is a single cluster-wide step (only invoked from server0).
echo ""
echo "Bootstrapping MongoDB replica set..."
bash "${SCRIPT_DIR}/init_mongodb_replicaset.sh" \
    || echo "WARNING: init_mongodb_replicaset.sh failed — investigate before running mongodb experiments"

echo ""
echo "02-setup.sh complete. Cluster is provisioned with mongod / etcd / zookeeper"
echo "installed and per-host config in place. Run scripts/04-nfs.sh next."
