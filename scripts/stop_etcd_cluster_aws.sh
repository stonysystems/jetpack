#!/bin/bash
# Stop the etcd cluster started by scripts/start_etcd_cluster_aws.sh.
# Idempotent — safe to run when etcd is already stopped.
#
# Usage:
#   bash scripts/stop_etcd_cluster_aws.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f setup.json ]] || { echo "[etcd] setup.json not found"; exit 1; }

USERNAME=$(jq -r '.server_username' setup.json)
ENV=$(jq -r '.environment' setup.json)
KEY="${SCRIPT_DIR}/../config/ssh/id_rsa"

if [[ "$ENV" != "aws" ]]; then
    echo "[etcd] AWS-specific script (setup.json says env=$ENV)"; exit 1
fi

N_REPLICA=5
declare -a IPS
for i in $(seq 0 $((N_REPLICA-1))); do
    ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
    [[ -n "$ip" && "$ip" != "null" ]] || continue
    IPS+=("$ip")
done

echo "[etcd] stopping etcd on server0..server$((N_REPLICA-1))..."
pids=()
for i in $(seq 0 $((N_REPLICA-1))); do
    ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USERNAME}@${IPS[$i]}" \
        "pkill -9 etcd 2>/dev/null; rm -rf /tmp/etcd-*.etcd 2>/dev/null; true" \
        >/dev/null 2>&1 &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
echo "[etcd] stopped and cleaned on $N_REPLICA hosts"
