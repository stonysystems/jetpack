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
# Get server0's member ID + the current leader's member ID via etcdctl
# endpoint status. JSON output: [{Endpoint, Status:{leader, header:{member_id}}}, …]
status_json=$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 \
    "${USERNAME}@${IPS[0]}" \
    "${ETCDCTL_BIN} --endpoints=${ALL_ENDPOINTS} endpoint status -w json 2>/dev/null") || status_json=""
if [[ -z "$status_json" ]]; then
    echo "[etcd] FATAL: could not query endpoint status — leader pin not enforced"
    exit 1
fi
s0_id=$(echo "$status_json" | jq -r ".[] | select(.Endpoint==\"${S0_ENDPOINT}\") | .Status.header.member_id")
cur_leader=$(echo "$status_json" | jq -r ".[] | select(.Endpoint==\"${S0_ENDPOINT}\") | .Status.leader")
if [[ -z "$s0_id" || -z "$cur_leader" || "$s0_id" == "null" || "$cur_leader" == "null" ]]; then
    echo "[etcd] FATAL: could not extract member/leader ids from status JSON"
    exit 1
fi
if [[ "$s0_id" == "$cur_leader" ]]; then
    echo "[etcd] leader already at server0 (member id=$s0_id)"
else
    # Find which endpoint holds the current leader: the entry whose
    # OWN member_id matches its OWN leader pointer. Comparing
    # number-vs-number within the same JSON entry sidesteps two
    # gotchas seen on first try (2026-05-05):
    #   (1) JSON-number vs bash-string type mismatch — jq's
    #       `select(member_id == "${cur_leader}")` returns nothing
    #       because one side is a number, the other a string.
    #   (2) Float-precision loss — etcd member_ids are 64-bit
    #       integers (~1e18), bigger than float64's safe-integer
    #       range (2^53 ≈ 9e15). jq before 1.7 silently rounds them.
    #       Comparing two fields parsed identically in the same
    #       entry is precision-stable; comparing across entries
    #       isn't.
    leader_endpoint=$(echo "$status_json" \
        | jq -r '.[] | select(.Status.header.member_id == .Status.leader) | .Endpoint' \
        | head -1)
    if [[ -z "$leader_endpoint" || "$leader_endpoint" == "null" ]]; then
        echo "[etcd] FATAL: status JSON has cur_leader=${cur_leader} but no entry with that member_id"
        echo "$status_json" | jq -c '.[] | {Endpoint, member_id: .Status.header.member_id, leader: .Status.leader}'
        exit 1
    fi
    # Strip "http://" and ":${ETCD_PORT}" to recover the IP for ssh.
    leader_ip="${leader_endpoint#http://}"
    leader_ip="${leader_ip%:*}"
    if [[ -z "$leader_ip" ]]; then
        echo "[etcd] FATAL: could not parse IP from leader endpoint '${leader_endpoint}'"
        exit 1
    fi
    echo "[etcd] current leader=$cur_leader at ${leader_endpoint}, server0 id=$s0_id — moving..."
    if ssh -i "$KEY" -o BatchMode=yes "${USERNAME}@${leader_ip}" \
        "${ETCDCTL_BIN} --endpoints=${leader_endpoint} move-leader ${s0_id}"; then
        echo "[etcd] leader moved to server0"
    else
        echo "[etcd] FATAL: move-leader failed even when targeted at the actual leader endpoint"
        echo "[etcd]   leader_endpoint=${leader_endpoint} s0_id=${s0_id}"
        exit 1
    fi
fi
