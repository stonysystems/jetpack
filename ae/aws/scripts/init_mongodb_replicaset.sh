#!/bin/bash
# One-shot bootstrap of the MongoDB replica set across server0..server4.
# Run this AFTER mongod has been installed and is running on every host
# (e.g. after scripts/02-setup.sh provisions the hosts).
#
# Sets up:
#   - replica set name "jetpack-rs"
#   - 5 members: server0..server4
#   - server0 (California) priority=2.0, others priority=1.0 → server0
#     wins elections by default. Required by start_mongodb_cluster.sh's
#     leader-pin step (see results/.../settings.md "Deployment topology").
#
# Idempotent — re-run is safe:
#   - If rs.status() succeeds, just rs.reconfig() with the new priorities.
#   - If rs.status() fails (NotYetInitialized), call rs.initiate().
#
# Usage:
#   bash scripts/init_mongodb_replicaset.sh
#
# Exit status:
#   0 — replica set is up with server0 as PRIMARY (or election in progress
#       with server0 favoured)
#   1 — bootstrap failed; inspect logs
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f setup.json ]] || { echo "[mongo-init] setup.json not found"; exit 1; }

USERNAME=$(jq -r '.server_username' setup.json)
N_SERVER=$(jq -r '.n_server' setup.json)
ENV=$(jq -r '.environment' setup.json)
KEY="${SCRIPT_DIR}/../config/ssh/id_rsa"

if [[ "$ENV" != "aws" ]]; then
    echo "[mongo-init] only AWS environment supported (setup.json says env=$ENV)"; exit 1
fi

N_REPLICA=5
declare -a IPS
for i in $(seq 0 $((N_REPLICA-1))); do
    ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
    [[ -n "$ip" && "$ip" != "null" ]] || { echo "[mongo-init] no IP for server $i"; exit 1; }
    IPS+=("$ip")
done

echo "[mongo-init] initializing replica set 'jetpack-rs' on:"
for i in $(seq 0 $((N_REPLICA-1))); do
    echo "  server${i}: ${IPS[$i]}:27017 (priority=$([ $i -eq 0 ] && echo 2.0 || echo 1.0))"
done

# Build the replica-set config doc as a JS expression.
RSCONF="{\\
  _id: \"jetpack-rs\",\\
  members: [\\
    {_id: 0, host: \"${IPS[0]}:27017\", priority: 2.0},\\
    {_id: 1, host: \"${IPS[1]}:27017\", priority: 1.0},\\
    {_id: 2, host: \"${IPS[2]}:27017\", priority: 1.0},\\
    {_id: 3, host: \"${IPS[3]}:27017\", priority: 1.0},\\
    {_id: 4, host: \"${IPS[4]}:27017\", priority: 1.0}\\
  ]\\
}"

# Pick mongosh if available, else mongo (older).
shell_cmd=""
for s in mongosh mongo; do
    if ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USERNAME}@${IPS[0]}" \
            "command -v $s >/dev/null 2>&1"; then
        shell_cmd="$s"
        break
    fi
done
if [[ -z "$shell_cmd" ]]; then
    echo "[mongo-init] FATAL: neither mongosh nor mongo available on server0"; exit 1
fi
echo "[mongo-init] using $shell_cmd on server0"

# Attempt rs.status() first; if it succeeds, the set already exists and
# we just reconfig. Otherwise initiate fresh.
status_ok=$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 \
    "${USERNAME}@${IPS[0]}" \
    "$shell_cmd --quiet --eval 'try { var r=rs.status(); print(r.ok==1 ? \"ok\" : \"notok\") } catch(e) { print(\"notinit\") }' 2>/dev/null \
        | tr -d '[:space:]'") || status_ok="notinit"

if [[ "$status_ok" == "ok" ]]; then
    echo "[mongo-init] replica set already initialized — reconfiguring priorities..."
    js="cfg = rs.conf();
        cfg.members = [
            {_id: 0, host: \"${IPS[0]}:27017\", priority: 2.0},
            {_id: 1, host: \"${IPS[1]}:27017\", priority: 1.0},
            {_id: 2, host: \"${IPS[2]}:27017\", priority: 1.0},
            {_id: 3, host: \"${IPS[3]}:27017\", priority: 1.0},
            {_id: 4, host: \"${IPS[4]}:27017\", priority: 1.0}
        ];
        rs.reconfig(cfg, {force: true});"
else
    echo "[mongo-init] replica set NOT initialized (status=$status_ok) — initiating..."
    js="rs.initiate({
            _id: \"jetpack-rs\",
            members: [
                {_id: 0, host: \"${IPS[0]}:27017\", priority: 2.0},
                {_id: 1, host: \"${IPS[1]}:27017\", priority: 1.0},
                {_id: 2, host: \"${IPS[2]}:27017\", priority: 1.0},
                {_id: 3, host: \"${IPS[3]}:27017\", priority: 1.0},
                {_id: 4, host: \"${IPS[4]}:27017\", priority: 1.0}
            ]
        });"
fi

result=$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15 \
    "${USERNAME}@${IPS[0]}" \
    "$shell_cmd --quiet --eval '$js' 2>&1") || true
echo "[mongo-init] mongosh output:"
echo "$result" | sed 's/^/    /'

# Wait for PRIMARY election to settle on server0.
echo "[mongo-init] waiting up to 60s for PRIMARY → server0..."
deadline=$((SECONDS + 60))
primary=""
while (( SECONDS < deadline )); do
    primary=$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 \
        "${USERNAME}@${IPS[0]}" \
        "$shell_cmd --quiet --eval 'try { var p=rs.status().members.find(m=>m.stateStr==\"PRIMARY\"); print(p ? p.name : \"\") } catch(e) { print(\"\") }' 2>/dev/null \
            | tr -d '[:space:]'") || primary=""
    if [[ "$primary" == "${IPS[0]}:27017" ]]; then
        echo "[mongo-init] PRIMARY = server0 (${primary})"
        exit 0
    fi
    sleep 3
done

echo "[mongo-init] FATAL: PRIMARY did not converge to server0 within 60s (last seen: ${primary:-none})"
echo "  Inspect rs.status() on server0 by hand and check member 0's priority."
exit 1
