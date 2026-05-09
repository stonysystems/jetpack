#!/bin/bash
# Stop the MongoDB replica set on all server0..server4 hosts in setup.json.
# Idempotent — safe to run when mongod is already stopped.
#
# Usage:
#   bash scripts/stop_mongodb_cluster.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f setup.json ]] || { echo "[mongodb] setup.json not found"; exit 1; }

USERNAME=$(jq -r '.server_username' setup.json)
N_SERVER=$(jq -r '.n_server' setup.json)
ENV=$(jq -r '.environment' setup.json)
KEY="${SCRIPT_DIR}/../config/ssh/id_rsa"

if [[ "$ENV" != "aws" ]]; then
    echo "[mongodb] only AWS environment supported (setup.json says env=$ENV)"; exit 1
fi

declare -a IPS
for i in $(seq 0 $((N_SERVER - 1))); do
    ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
    [[ -n "$ip" && "$ip" != "null" ]] || continue
    IPS+=("$ip")
done
N_REPLICA=5

echo "[mongodb] stopping mongod on server0..server$((N_REPLICA-1))..."
pids=()
for i in $(seq 0 $((N_REPLICA-1))); do
    ssh -i "$KEY" -o BatchMode=yes "${USERNAME}@${IPS[$i]}" \
        "sudo systemctl stop mongod 2>/dev/null; true" >/dev/null 2>&1 &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
echo "[mongodb] stopped on $N_REPLICA hosts"
