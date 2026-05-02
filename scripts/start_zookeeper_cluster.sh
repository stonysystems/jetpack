#!/bin/bash
# Start a 5-node (jetpack-patched) ZooKeeper ensemble across server0..server4
# in setup.json (AWS environment), then wait until every node responds
# 'imok' to the four-letter `ruok` health check.
#
# Topology contract (set at host bootstrap, NOT by this script):
#   - 5 zkServer instances on server0..server4 (one per region).
#   - zoo.cfg on each host has the 5-node ensemble (server.1..server.5
#     pointing at server0..server4 IPs).
#   - myid file: server0 must hold the HIGHEST sid (e.g. myid=5) so it
#     wins ZooKeeper FastLeaderElection on a fresh start. With equal
#     ZXIDs after restart, the highest-sid node becomes leader.
#       server0 → myid=5
#       server1 → myid=4
#       server2 → myid=3
#       server3 → myid=2
#       server4 → myid=1
#   - Four-letter-word allow-list in zoo.cfg includes ruok / srvr:
#       4lw.commands.whitelist=ruok,srvr,stat,mntr
#
# This script post-starts taskset-pins zkServer (the QuorumPeerMain JVM)
# to BACKEND_CORE on each host so its CPU usage shows up on the same
# core as the deptran server thread.
#
# Usage:
#   bash scripts/start_zookeeper_cluster.sh
#
# Env knobs:
#   READY_TIMEOUT  seconds to wait for all nodes to respond imok (default 60)
#   ZK_PORT        client port (default 2181)
#   ZKSERVER_BIN   remote zkServer.sh path (default zkServer.sh, on PATH)
#   BACKEND_CORE   CPU core to pin zkServer JVM to (default 1; "" to skip)
#
# Exit status:
#   0 — all 5 nodes healthy AND server0 is the LEADER
#   1 — at least one node failed liveness within READY_TIMEOUT
#       OR server0 is not the LEADER (warning, not enforced — see notes)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f setup.json ]] || { echo "[zookeeper] setup.json not found"; exit 1; }

USERNAME=$(jq -r '.server_username' setup.json)
N_SERVER=$(jq -r '.n_server' setup.json)
ENV=$(jq -r '.environment' setup.json)
KEY="${SCRIPT_DIR}/../config/ssh/id_rsa"
READY_TIMEOUT="${READY_TIMEOUT:-360}"  # bumped from 120: cross-region FastLeaderElection on a wiped data dir can take 3-5 min before the first peer connection succeeds (election retries every ~50s and other peers are starting in parallel)
ZK_PORT="${ZK_PORT:-2181}"
ZKSERVER_BIN="${ZKSERVER_BIN:-zkServer.sh}"
BACKEND_CORE="${BACKEND_CORE:-1}"

if [[ "$ENV" != "aws" ]]; then
    echo "[zookeeper] only AWS environment supported (setup.json says env=$ENV)"; exit 1
fi

N_REPLICA=5
declare -a IPS
for i in $(seq 0 $((N_REPLICA-1))); do
    ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
    [[ -n "$ip" && "$ip" != "null" ]] || { echo "[zookeeper] no IP for server $i"; exit 1; }
    IPS+=("$ip")
done

echo "[zookeeper] (re)starting zookeeper systemd service on server0..server$((N_REPLICA-1))..."
# 2026-05-02: zkServer.sh is NOT on PATH on these AWS hosts — zookeeper is
# managed by /etc/init.d/zookeeper via systemd (zookeeper.service, enabled
# on boot, started by the LSB init script that calls
# /usr/share/zookeeper/bin/zkServer.sh under the hood with proper user
# /env). The service is auto-started at instance boot, so usually we just
# need to restart it to pick up any config changes and reset state.
# Wipe the data dir as part of the restart for a guaranteed-clean ensemble
# (myid file is regenerated below to match the highest-sid-on-server0
# convention).
pids=()
for i in $(seq 0 $((N_REPLICA-1))); do
    sid=$(( N_REPLICA - i ))   # server0 → 5, …, server4 → 1
    ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USERNAME}@${IPS[$i]}" \
        "sudo systemctl stop zookeeper 2>/dev/null; \
         sudo pkill -9 -f QuorumPeerMain 2>/dev/null; \
         sudo pkill -9 -f 'org.apache.zookeeper' 2>/dev/null; \
         sleep 1; \
         sudo rm -rf /var/lib/zookeeper/version-2 /var/lib/zookeeper/zookeeper_server.pid 2>/dev/null; \
         echo '${sid}' | sudo tee /var/lib/zookeeper/myid >/dev/null; \
         sudo chown -R zookeeper:zookeeper /var/lib/zookeeper 2>/dev/null; \
         true" \
        >/dev/null 2>&1 &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
sleep 3

pids=()
for i in $(seq 0 $((N_REPLICA-1))); do
    ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USERNAME}@${IPS[$i]}" \
        "sudo systemctl start zookeeper" >/dev/null 2>&1 &
    pids+=($!)
done
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=$((fail+1)); done
if (( fail > 0 )); then
    echo "[zookeeper] WARNING: $fail / $N_REPLICA systemctl start commands had non-zero exit"
fi
sleep 5

echo "[zookeeper] waiting up to ${READY_TIMEOUT}s for ruok->imok on all $N_REPLICA nodes..."
deadline=$((SECONDS + READY_TIMEOUT))
declare -a ready=(0 0 0 0 0)
ready_count=0
while (( ready_count < N_REPLICA && SECONDS < deadline )); do
    for i in $(seq 0 $((N_REPLICA-1))); do
        (( ready[i] )) && continue
        # Use nc with -w for timeout. ZK requires the four-letter command
        # 'ruok' (4 bytes) and replies 'imok'.  Some installs disable
        # four-letter commands by default; if so, fall back to 'stat'.
        if ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=3 "${USERNAME}@${IPS[$i]}" \
            "echo ruok | nc -q 1 -w 2 ${IPS[$i]} ${ZK_PORT} 2>/dev/null \
                | grep -q '^imok$'" 2>/dev/null \
            || ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=3 "${USERNAME}@${IPS[$i]}" \
                "echo srvr | nc -q 1 -w 2 ${IPS[$i]} ${ZK_PORT} 2>/dev/null \
                    | grep -qE 'Mode: (leader|follower|standalone)'" 2>/dev/null; then
            ready[i]=1
            ready_count=$((ready_count+1))
            echo "  server$i (${IPS[$i]}): imok"
        fi
    done
    (( ready_count < N_REPLICA )) && sleep 3
done
if (( ready_count < N_REPLICA )); then
    echo "[zookeeper] only $ready_count / $N_REPLICA responded within ${READY_TIMEOUT}s — retrying any not-yet-ready hosts (sudo systemctl restart zookeeper)..."
    for i in $(seq 0 $((N_REPLICA-1))); do
        (( ready[i] )) && continue
        ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USERNAME}@${IPS[$i]}" \
            "sudo systemctl restart zookeeper" \
            >/dev/null 2>&1 &
    done
    wait
    sleep 5
    # second wait, half the original timeout
    rd2=$((READY_TIMEOUT / 2))
    deadline2=$((SECONDS + rd2))
    while (( ready_count < N_REPLICA && SECONDS < deadline2 )); do
        for i in $(seq 0 $((N_REPLICA-1))); do
            (( ready[i] )) && continue
            if ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=3 "${USERNAME}@${IPS[$i]}" \
                "echo ruok | nc -q 1 -w 2 ${IPS[$i]} ${ZK_PORT} 2>/dev/null \
                    | grep -q '^imok$'" 2>/dev/null \
                || ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=3 "${USERNAME}@${IPS[$i]}" \
                    "echo srvr | nc -q 1 -w 2 ${IPS[$i]} ${ZK_PORT} 2>/dev/null \
                        | grep -qE 'Mode: (leader|follower|standalone)'" 2>/dev/null; then
                ready[i]=1
                ready_count=$((ready_count+1))
                echo "  server$i (${IPS[$i]}): imok (after retry)"
            fi
        done
        (( ready_count < N_REPLICA )) && sleep 3
    done
fi
if (( ready_count < N_REPLICA )); then
    echo "[zookeeper] FATAL: only $ready_count / $N_REPLICA responded after retry"
    for i in $(seq 0 $((N_REPLICA-1))); do
        (( ready[i] )) || echo "  server$i (${IPS[$i]}) did not respond"
    done
    echo "[zookeeper] hint: enable four-letter cmds with -Dzookeeper.4lw.commands.whitelist=ruok,srvr,stat,mntr in zoo.cfg"
    exit 1
fi
echo "[zookeeper] ensemble up: $N_REPLICA / $N_REPLICA nodes healthy"

# Post-start taskset-pin zkServer (QuorumPeerMain JVM) to BACKEND_CORE
# on each host. zkServer.sh launches a JVM in background; we set
# affinity on the resulting pid via taskset -p.
if [[ -n "$BACKEND_CORE" ]]; then
    echo "[zookeeper] pinning QuorumPeerMain → core ${BACKEND_CORE}..."
    pin_fail=0
    for i in $(seq 0 $((N_REPLICA-1))); do
        ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USERNAME}@${IPS[$i]}" \
            "pid=\$(pgrep -f QuorumPeerMain | head -1); \
             if [[ -n \"\$pid\" ]]; then \
                sudo taskset -p -c ${BACKEND_CORE} \$pid >/dev/null 2>&1 \
                    && echo \"  server${i} (pid=\$pid): pinned to core ${BACKEND_CORE}\" \
                    || echo \"  server${i} (pid=\$pid): TASKSET FAILED\"; \
             else echo \"  server${i}: NO QuorumPeerMain pid found\"; fi" \
            || pin_fail=$((pin_fail + 1))
    done
    (( pin_fail > 0 )) && echo "[zookeeper] WARNING: $pin_fail / $N_REPLICA pinning ssh commands had errors"
fi

# Verify server0 is the LEADER. ZooKeeper has no built-in leader-move
# command; if server0 is not the leader, the operator must (a) confirm
# myid file ordering on hosts, (b) re-run this script (which restarts
# the ensemble — fresh-start election picks the highest-myid node), or
# (c) bring down the current leader to trigger a re-election.
echo "[zookeeper] verifying LEADER → server0..."
mode_s0=$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USERNAME}@${IPS[0]}" \
    "echo srvr | nc -q 1 -w 2 ${IPS[0]} ${ZK_PORT} 2>/dev/null | awk -F': ' '/^Mode:/ {print \$2}'") \
    || mode_s0=""
case "$mode_s0" in
    leader)
        echo "[zookeeper] server0 is LEADER" ;;
    follower|standalone)
        echo "[zookeeper] WARNING: server0 is '${mode_s0}', not leader."
        echo "  Check myid file ordering on hosts — server0 must have the HIGHEST sid"
        echo "  (set during host bootstrap, e.g. myid=5 on server0). Without that,"
        echo "  ZK FastLeaderElection picks the wrong leader on fresh start."
        ;;
    "")
        echo "[zookeeper] WARNING: could not query srvr on server0 (4lw command not whitelisted?)"
        ;;
    *)
        echo "[zookeeper] WARNING: server0 reports unknown Mode='${mode_s0}'"
        ;;
esac
