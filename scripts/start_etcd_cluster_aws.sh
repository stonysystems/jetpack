#!/bin/bash
# Start a 5-node (jetpack-patched) etcd cluster across server0..server4 in
# setup.json (AWS environment). Mirrors scripts/start_etcd_cluster.sh
# (zoo) but reads hosts from setup.json instead of hard-coded IPs.
#
# Usage:
#   bash scripts/start_etcd_cluster_aws.sh
#
# Env knobs:
#   READY_TIMEOUT  seconds to wait for all nodes to be healthy (default 60)
#   ETCD_BIN       remote path to etcd binary (default $HOME/.local/bin/etcd)
#   ETCDCTL_BIN    remote path to etcdctl    (default $HOME/.local/bin/etcdctl)
#   ETCD_PORT      client port (default 2379)
#   ETCD_PEER_PORT peer port   (default 2380)
#   BACKEND_CORE   CPU core to pin etcd to on each host (default 1, matching
#                  the deptran server thread). Set to "" to skip pinning.
#
# Topology contract:
#   - All 5 etcd nodes run on server0..server4 (one per region).
#   - etcd process on each host is taskset-pinned to BACKEND_CORE.
#   - After liveness, the cluster leader is moved to server0 (California /
#     aws00). Camera-ready expects fixed leader at server0 so commit-RTT is
#     reproducible and JetPack's adaptive throttle (FP_LO/FP_HI on leader
#     CPU) measures consistent conditions across runs.
#
# Exit status:
#   0 — all 5 nodes healthy
#   1 — at least one node failed liveness within READY_TIMEOUT
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f setup.json ]] || { echo "[etcd] setup.json not found"; exit 1; }

USERNAME=$(jq -r '.server_username' setup.json)
N_SERVER=$(jq -r '.n_server' setup.json)
ENV=$(jq -r '.environment' setup.json)
KEY="${SCRIPT_DIR}/../config/ssh/id_rsa"
READY_TIMEOUT="${READY_TIMEOUT:-60}"
ETCD_BIN="${ETCD_BIN:-\$HOME/.local/bin/etcd}"
ETCDCTL_BIN="${ETCDCTL_BIN:-\$HOME/.local/bin/etcdctl}"
ETCD_PORT="${ETCD_PORT:-2379}"
ETCD_PEER_PORT="${ETCD_PEER_PORT:-2380}"
BACKEND_CORE="${BACKEND_CORE:-1}"

if [[ "$ENV" != "aws" ]]; then
    echo "[etcd] AWS-specific script (setup.json says env=$ENV); use start_etcd_cluster.sh for zoo"; exit 1
fi

# Build the taskset prefix once (or empty if pinning is disabled).
if [[ -n "$BACKEND_CORE" ]]; then
    TASKSET_PREFIX="taskset -c ${BACKEND_CORE} "
else
    TASKSET_PREFIX=""
fi

N_REPLICA=5
declare -a IPS NAMES
for i in $(seq 0 $((N_REPLICA-1))); do
    ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
    [[ -n "$ip" && "$ip" != "null" ]] || { echo "[etcd] no IP for server $i"; exit 1; }
    IPS+=("$ip")
    NAMES+=("server$i")
done

# Build initial-cluster string: name1=peer_url1,name2=peer_url2,...
CLUSTER=""
for i in $(seq 0 $((N_REPLICA-1))); do
    [[ -n "$CLUSTER" ]] && CLUSTER+=","
    CLUSTER+="${NAMES[$i]}=http://${IPS[$i]}:${ETCD_PEER_PORT}"
done

echo "[etcd] starting 5-node cluster"
echo "  cluster: $CLUSTER"

# Kill any prior etcd + clean state dir on all hosts.
pids=()
for i in $(seq 0 $((N_REPLICA-1))); do
    ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USERNAME}@${IPS[$i]}" \
        "pkill -9 etcd 2>/dev/null; rm -rf /tmp/etcd-${NAMES[$i]}.etcd 2>/dev/null; true" \
        >/dev/null 2>&1 &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
sleep 2

# Launch etcd on each host (background, taskset-pinned, redirect to /tmp/etcd-<name>.log).
pids=()
for i in $(seq 0 $((N_REPLICA-1))); do
    # Listen on 0.0.0.0 (NOT public IP) — AWS EC2 instances don't have the
    # public IP on their network interface; binding fails with
    # "cannot assign requested address" if you try. Advertise the public IP
    # so cross-region peers can reach this node via NAT.
    ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USERNAME}@${IPS[$i]}" \
        "nohup ${TASKSET_PREFIX}${ETCD_BIN} \
            --name=${NAMES[$i]} \
            --data-dir=/tmp/etcd-${NAMES[$i]}.etcd \
            --listen-peer-urls=http://0.0.0.0:${ETCD_PEER_PORT} \
            --initial-advertise-peer-urls=http://${IPS[$i]}:${ETCD_PEER_PORT} \
            --listen-client-urls=http://0.0.0.0:${ETCD_PORT} \
            --advertise-client-urls=http://${IPS[$i]}:${ETCD_PORT} \
            --initial-cluster-token=jetpack-etcd-aws \
            --initial-cluster=${CLUSTER} \
            --initial-cluster-state=new \
            --logger=zap --log-level=warn \
            > /tmp/etcd-${NAMES[$i]}.log 2>&1 &" \
        >/dev/null 2>&1 &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
sleep 3

echo "[etcd] waiting up to ${READY_TIMEOUT}s for endpoint health..."
deadline=$((SECONDS + READY_TIMEOUT))
declare -a ready=(0 0 0 0 0)
ready_count=0
while (( ready_count < N_REPLICA && SECONDS < deadline )); do
    for i in $(seq 0 $((N_REPLICA-1))); do
        (( ready[i] )) && continue
        if ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=3 "${USERNAME}@${IPS[$i]}" \
            "${ETCDCTL_BIN} --endpoints=http://${IPS[$i]}:${ETCD_PORT} endpoint health 2>&1 \
                | head -1 | grep -q 'is healthy'" 2>/dev/null; then
            ready[i]=1
            ready_count=$((ready_count+1))
            echo "  ${NAMES[$i]} (${IPS[$i]}): healthy"
        fi
    done
    (( ready_count < N_REPLICA )) && sleep 3
done
if (( ready_count < N_REPLICA )); then
    echo "[etcd] FATAL: only $ready_count / $N_REPLICA healthy within ${READY_TIMEOUT}s"
    for i in $(seq 0 $((N_REPLICA-1))); do
        (( ready[i] )) && continue
        echo "  ${NAMES[$i]} log tail:"
        ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=3 "${USERNAME}@${IPS[$i]}" \
            "tail -20 /tmp/etcd-${NAMES[$i]}.log" 2>&1 | sed "s/^/    /"
    done
    exit 1
fi
echo "[etcd] cluster up: $N_REPLICA / $N_REPLICA nodes healthy"

# Move the raft leader to server0 if it is not already there. The
# camera-ready expects a fixed California-leader so that commit-RTT and
# the JetPack adaptive throttle's CPU readings are reproducible.
#
# Fix E1 (set 2026-05-05): `move-leader` is an admin RPC that ONLY the
# current leader's endpoint can execute. The previous version sent it
# to ${S0_ENDPOINT} unconditionally; if server0 was a follower it
# returned "etcdserver: not leader" and the script silently continued
# with the leader still in some other region — adding ~one extra
# cross-region hop to every etcd write at server0/CA in 2026-05-02
# data. The fix: parse the leader's endpoint from `endpoint status`,
# ssh to that host, run `move-leader` from there. Every error path
# is now a hard exit so a misconfigured leader doesn't quietly
# corrupt v2's etcd numbers.
echo "[etcd] verifying / moving leader → server0..."
S0_ENDPOINT="http://${IPS[0]}:${ETCD_PORT}"
ALL_ENDPOINTS=""
for i in $(seq 0 $((N_REPLICA-1))); do
    [[ -n "$ALL_ENDPOINTS" ]] && ALL_ENDPOINTS+=","
    ALL_ENDPOINTS+="http://${IPS[$i]}:${ETCD_PORT}"
done
# Fix E1, third try (set 2026-05-05). Two earlier attempts hit two
# different facets of the same root cause: jq parses 64-bit integers
# (~1e18) as float64, which can't represent them exactly past 2^53.
#
#   try 1: select(member_id == "${cur_leader}")  — string vs number type
#          mismatch (filter found nothing).
#   try 2: select(member_id == .Status.leader)   — type-stable filter
#          finds the right entry, but s0_id passed to move-leader was
#          extracted via `jq -r .Status.header.member_id`, which prints
#          a float-rounded string (6578129159743637182 → 6578129159743638000).
#          etcdctl rejects the rounded value with "strconv.ParseUint:
#          parsing ...: value out of range" because the rounded number
#          maps to a member that doesn't exist.
#
# Real fix: never let jq touch member IDs. Use `etcdctl member list -w
# table` which prints IDs in HEX (no float64 trip). Find server0's hex
# member id by matching its CLIENT URL. Use `endpoint status -w table`
# to find the leader endpoint via the `IS LEADER` column. Both lookups
# are precision-clean.
member_table=$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 \
    "${USERNAME}@${IPS[0]}" \
    "${ETCDCTL_BIN} --endpoints=${ALL_ENDPOINTS} member list -w table 2>/dev/null") || member_table=""
status_table=$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 \
    "${USERNAME}@${IPS[0]}" \
    "${ETCDCTL_BIN} --endpoints=${ALL_ENDPOINTS} endpoint status -w table 2>/dev/null") || status_table=""
if [[ -z "$member_table" || -z "$status_table" ]]; then
    echo "[etcd] FATAL: could not query etcd member/endpoint state — leader pin not enforced"
    exit 1
fi
# member list -w table format (one row per member, 7 cols):
#   | ID (hex) | STATUS | NAME | PEER ADDRS | CLIENT ADDRS | IS LEARNER | (extra cols) |
# Field 2 of the | -separated row is the hex ID; field 6 is CLIENT ADDRS.
s0_id_hex=$(echo "$member_table" \
    | awk -F'|' -v s0="${S0_ENDPOINT}" '
        NR > 3 && $0 ~ /^\|/ {
            cli = $6; gsub(/^[ \t]+|[ \t]+$/, "", cli);
            if (cli == s0) { id = $2; gsub(/^[ \t]+|[ \t]+$/, "", id); print id; exit }
        }')
if [[ -z "$s0_id_hex" ]]; then
    echo "[etcd] FATAL: could not extract server0's member id from member-list table"
    echo "$member_table"
    exit 1
fi
# endpoint status -w table format (10 cols, one row per endpoint):
#   | ENDPOINT | ID (hex) | VERSION | DB SIZE | IS LEADER | IS LEARNER | RAFT TERM | ... |
# Find the row where IS LEADER (col 6) is "true"; col 2 is the leader ENDPOINT.
leader_endpoint=$(echo "$status_table" \
    | awk -F'|' '
        NR > 3 && $0 ~ /^\|/ {
            is_leader = $6; gsub(/^[ \t]+|[ \t]+$/, "", is_leader);
            if (is_leader == "true") {
                ep = $2; gsub(/^[ \t]+|[ \t]+$/, "", ep); print ep; exit
            }
        }')
if [[ -z "$leader_endpoint" ]]; then
    echo "[etcd] FATAL: no IS LEADER=true row in endpoint status table"
    echo "$status_table"
    exit 1
fi
if [[ "$leader_endpoint" == "$S0_ENDPOINT" ]]; then
    echo "[etcd] leader already at server0 (id=$s0_id_hex)"
else
    leader_ip="${leader_endpoint#http://}"
    leader_ip="${leader_ip%:*}"
    if [[ -z "$leader_ip" ]]; then
        echo "[etcd] FATAL: could not parse IP from leader endpoint '${leader_endpoint}'"
        exit 1
    fi
    echo "[etcd] current leader at ${leader_endpoint}, moving to server0 (id=$s0_id_hex)..."
    if ssh -i "$KEY" -o BatchMode=yes "${USERNAME}@${leader_ip}" \
        "${ETCDCTL_BIN} --endpoints=${leader_endpoint} move-leader ${s0_id_hex}"; then
        echo "[etcd] leader moved to server0"
    else
        echo "[etcd] FATAL: move-leader failed even when targeted at the actual leader endpoint"
        echo "[etcd]   leader_endpoint=${leader_endpoint} s0_id=${s0_id}"
        exit 1
    fi
fi
