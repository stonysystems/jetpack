#!/bin/bash
# Stop the ZooKeeper ensemble started by scripts/start_zookeeper_cluster.sh.
# Idempotent — safe to run when zkServer is already stopped.
#
# Usage:
#   bash scripts/stop_zookeeper_cluster.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f setup.json ]] || { echo "[zookeeper] setup.json not found"; exit 1; }

USERNAME=$(jq -r '.server_username' setup.json)
ENV=$(jq -r '.environment' setup.json)
KEY="${SCRIPT_DIR}/../config/ssh/id_rsa"
ZKSERVER_BIN="${ZKSERVER_BIN:-zkServer.sh}"

if [[ "$ENV" != "aws" ]]; then
    echo "[zookeeper] AWS-specific script (setup.json says env=$ENV)"; exit 1
fi

N_REPLICA=5
declare -a IPS
for i in $(seq 0 $((N_REPLICA-1))); do
    ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
    [[ -n "$ip" && "$ip" != "null" ]] || continue
    IPS+=("$ip")
done

echo "[zookeeper] stopping zookeeper systemd service on server0..server$((N_REPLICA-1))..."
pids=()
for i in $(seq 0 $((N_REPLICA-1))); do
    ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USERNAME}@${IPS[$i]}" \
        "sudo systemctl stop zookeeper 2>/dev/null; sudo pkill -9 -f 'org.apache.zookeeper' 2>/dev/null; true" \
        >/dev/null 2>&1 &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
echo "[zookeeper] stopped on $N_REPLICA hosts"
