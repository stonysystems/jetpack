#!/bin/bash
# Start the (jetpack-patched) MongoDB replica set across all servers in
# setup.json and wait until every node responds to `ping`. Idempotent —
# if mongod is already running it'll be restarted.
#
# Topology contract (set at host bootstrap, NOT by this script):
#   - 5 mongod instances on server0..server4 (one per region).
#   - Each mongod systemd unit has CPUAffinity=1 (matching the deptran
#     server thread). Persistent drop-in:
#       /etc/systemd/system/mongod.service.d/cpuaffinity.conf
#         [Service]
#         CPUAffinity=1
#     This script verifies the affinity took effect after restart.
#   - Replica-set bootstrap done once during host setup (rs.initiate),
#     with member 0 (server0 / California) configured priority=2.0 and
#     all others priority=1.0 so server0 is the preferred PRIMARY.
#
# Both the CPU affinity drop-in and the replica-set priorities should
# be installed by scripts/aws_setup_script.sh / scripts/02-setup.sh on
# fresh hosts.
#
# Usage:
#   bash scripts/start_mongodb_cluster.sh
#
# Env knobs:
#   READY_TIMEOUT       seconds to wait for all nodes to respond to ping (default 60)
#   BACKEND_CORE        expected CPU affinity for mongod (default 1, advisory only)
#   MONGODB_NO_JOURNAL  if =1, toggle storage.journal.enabled=false in /etc/mongod.conf
#                       on each replica BEFORE the systemctl restart, mirroring etcd's
#                       --unsafe-no-fsync. Default 0 (journal stays at whatever the
#                       persisted config says, normally enabled). Setting to 0 (or
#                       leaving unset) restores enabled=true.
#                       After the experiment, run with MONGODB_NO_JOURNAL=0 to flip
#                       it back so the next workload gets default durability.
#
# Exit status:
#   0 — all nodes healthy AND server0 is PRIMARY
#   1 — at least one node failed liveness OR server0 is not PRIMARY
set -uo pipefail

MONGODB_NO_JOURNAL="${MONGODB_NO_JOURNAL:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f setup.json ]] || { echo "[mongodb] setup.json not found"; exit 1; }

USERNAME=$(jq -r '.server_username' setup.json)
N_SERVER=$(jq -r '.n_server' setup.json)
ENV=$(jq -r '.environment' setup.json)
KEY="${SCRIPT_DIR}/../config/ssh/id_rsa"
READY_TIMEOUT="${READY_TIMEOUT:-60}"
BACKEND_CORE="${BACKEND_CORE:-1}"

if [[ "$ENV" != "aws" ]]; then
    echo "[mongodb] only AWS environment supported (setup.json says env=$ENV)"; exit 1
fi

declare -a IPS
for i in $(seq 0 $((N_SERVER - 1))); do
    ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
    [[ -n "$ip" && "$ip" != "null" ]] || { echo "[mongodb] no IP for server $i"; exit 1; }
    IPS+=("$ip")
done
# Replica set lives on server0..server4 (5 nodes); spare hosts (5..9) are
# clients only and don't run mongod.
N_REPLICA=5

# NOTE (2026-05-09): MongoDB 7+ removed `storage.journal.enabled` for
# WiredTiger — the journal is mandatory at the server. The fsync-off
# equivalent is now a CLIENT-SIDE knob: pass `journal=false` in the
# mongocxx URI so writes ack as soon as they're applied in memory,
# without waiting for journal flush. That's plumbed via the
# `--enable-mongodb-no-journal` build flag in wscript (which defines
# MONGODB_NO_JOURNAL=1 → handler.h picks the journal=false URI).
#
# So this script no longer edits /etc/mongod.conf. The MONGODB_NO_JOURNAL
# env knob now serves only as a sanity-log entry (the actual toggle
# happens at deptran build time, not here).
if [[ "$MONGODB_NO_JOURNAL" == "1" ]]; then
    echo "[mongodb] MONGODB_NO_JOURNAL=1 — assuming the deptran binary was built with --enable-mongodb-no-journal so its mongocxx URI carries journal=false."
fi

echo "[mongodb] (re)starting mongod on server0..server$((N_REPLICA-1))..."
# Server0 first (it is the NFS host and typical replica-set primary), then
# the others in parallel.
ssh -i "$KEY" -o BatchMode=yes "${USERNAME}@${IPS[0]}" \
    "sudo systemctl restart mongod" \
    || { echo "[mongodb] FATAL: server0 restart failed"; exit 1; }
pids=()
for i in $(seq 1 $((N_REPLICA-1))); do
    ssh -i "$KEY" -o BatchMode=yes "${USERNAME}@${IPS[$i]}" \
        "sudo systemctl restart mongod" &
    pids+=($!)
done
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=$((fail+1)); done
if (( fail > 0 )); then
    echo "[mongodb] FATAL: $fail / $((N_REPLICA-1)) restart commands failed"; exit 1
fi

echo "[mongodb] waiting up to ${READY_TIMEOUT}s for ping on all $N_REPLICA nodes..."
deadline=$((SECONDS + READY_TIMEOUT))
declare -a ready=(0 0 0 0 0)
ready_count=0
while (( ready_count < N_REPLICA && SECONDS < deadline )); do
    for i in $(seq 0 $((N_REPLICA-1))); do
        (( ready[i] )) && continue
        if ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USERNAME}@${IPS[$i]}" \
            "mongosh --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null \
                | tr -d '[:space:]' \
                | grep -q '^1$'" 2>/dev/null \
            || ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USERNAME}@${IPS[$i]}" \
                "mongo --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null \
                | tr -d '[:space:]' \
                | grep -q '^1$'" 2>/dev/null; then
            ready[i]=1
            ready_count=$((ready_count + 1))
            echo "  server$i (${IPS[$i]}): READY"
        fi
    done
    (( ready_count < N_REPLICA )) && sleep 3
done
if (( ready_count < N_REPLICA )); then
    echo "[mongodb] FATAL: only $ready_count / $N_REPLICA nodes responded within ${READY_TIMEOUT}s"
    for i in $(seq 0 $((N_REPLICA-1))); do
        (( ready[i] )) || echo "  server$i (${IPS[$i]}) did not respond"
    done
    exit 1
fi
echo "[mongodb] cluster up: $N_REPLICA / $N_REPLICA nodes healthy"

# Advisory: confirm mongod is actually pinned to BACKEND_CORE on each host.
# (Just a sanity check — affinity must be set persistently in the systemd
# drop-in; this script does NOT enforce it because the drop-in lives
# outside the repo's tracked state.)
echo "[mongodb] verifying CPU affinity (expect Cpus_allowed_list: ${BACKEND_CORE})..."
mismatched=0
for i in $(seq 0 $((N_REPLICA-1))); do
    # mongod systemd unit gives the process a stable name; extract its main pid.
    actual=$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USERNAME}@${IPS[$i]}" \
        "pid=\$(systemctl show -p MainPID --value mongod 2>/dev/null); \
         [[ -n \"\$pid\" && \"\$pid\" != 0 ]] && grep '^Cpus_allowed_list:' /proc/\$pid/status | awk '{print \$2}'" \
        2>/dev/null)
    if [[ "$actual" != "$BACKEND_CORE" ]]; then
        echo "  server$i: Cpus_allowed_list='${actual:-<unknown>}' (expected ${BACKEND_CORE})"
        mismatched=$((mismatched + 1))
    fi
done
if (( mismatched > 0 )); then
    echo "[mongodb] WARNING: $mismatched / $N_REPLICA hosts have unexpected CPU affinity."
    echo "  Install the drop-in /etc/systemd/system/mongod.service.d/cpuaffinity.conf"
    echo "  with [Service] CPUAffinity=${BACKEND_CORE}, then 'sudo systemctl daemon-reload'"
    echo "  and re-run this script. (Do not edit on hosts; commit to scripts/02-setup.sh.)"
fi

# Verify server0 is the replica-set PRIMARY. If not, attempt a stepDown of
# the current PRIMARY so the next election (with priorities set per the
# topology contract above) lands on server0.
echo "[mongodb] verifying / forcing PRIMARY → server0..."
attempt=0
while (( attempt < 3 )); do
    primary=$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USERNAME}@${IPS[0]}" \
        "mongosh --quiet --eval 'try { var p=rs.status().members.find(m=>m.stateStr==\"PRIMARY\"); print(p ? p.name : \"\") } catch(e) { print(\"\") }' 2>/dev/null \
            | tr -d '[:space:]'") || primary=""
    if [[ "$primary" == "${IPS[0]}:27017" || "$primary" == server0* ]]; then
        echo "[mongodb] PRIMARY at server0 (${primary})"
        break
    fi
    if [[ -z "$primary" ]]; then
        echo "[mongodb] WARNING: rs.status() returned no PRIMARY (election in flight?)"
    else
        echo "[mongodb] PRIMARY at ${primary} — issuing stepDown to force re-election..."
        # stepDown on the current primary; with priorities=2.0 on server0
        # and 1.0 on others, re-election should land on server0.
        ssh -i "$KEY" -o BatchMode=yes "${USERNAME}@${IPS[0]}" \
            "mongosh --quiet --host ${primary} --eval 'try { rs.stepDown(60) } catch(e) { print(e) }'" \
            >/dev/null 2>&1 || true
    fi
    attempt=$((attempt + 1))
    sleep 8
done
if [[ "$primary" != "${IPS[0]}:27017" && "$primary" != server0* ]]; then
    echo "[mongodb] FATAL: could not move PRIMARY to server0 after 3 attempts (last seen: ${primary:-none})"
    echo "  Check that replica-set members[0] has priority=2.0 (set during rs.initiate)"
    exit 1
fi
