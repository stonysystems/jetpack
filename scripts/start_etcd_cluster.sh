#!/bin/bash
# Start a 5-node etcd cluster across zoo0..zoo4.
# Each node runs on localhost:2379 (client) and port 2380 (peer).
# The cluster is a real 5-replica etcd cluster; Janus connects to the local
# etcd on each replica host (see src/deptran/etcd/server.h).

set -e

IPS=(130.245.173.101 130.245.173.102 130.245.173.103 130.245.173.104 130.245.173.105)
NAMES=(zoo0 zoo1 zoo2 zoo3 zoo4)

# Initial cluster string: name=peer_url
CLUSTER=""
for i in "${!IPS[@]}"; do
  if [ $i -ne 0 ]; then CLUSTER+="," ; fi
  CLUSTER+="${NAMES[$i]}=http://${IPS[$i]}:2380"
done

echo "[etcd] starting 5-node cluster: $CLUSTER"

for i in "${!IPS[@]}"; do
  ip="${IPS[$i]}"
  name="${NAMES[$i]}"
  ssh -o ConnectTimeout=5 "ztang@$ip" "pkill -9 etcd 2>/dev/null; rm -rf /tmp/etcd-${name}.etcd" &
done
wait
sleep 2

for i in "${!IPS[@]}"; do
  ip="${IPS[$i]}"
  name="${NAMES[$i]}"
  ssh -o ConnectTimeout=5 "ztang@$ip" "nohup \$HOME/.local/bin/etcd \
    --name=${name} \
    --data-dir=/tmp/etcd-${name}.etcd \
    --listen-peer-urls=http://${ip}:2380 \
    --initial-advertise-peer-urls=http://${ip}:2380 \
    --listen-client-urls=http://${ip}:2379,http://127.0.0.1:2379 \
    --advertise-client-urls=http://${ip}:2379 \
    --initial-cluster-token=jetpack-etcd \
    --initial-cluster=${CLUSTER} \
    --initial-cluster-state=new \
    --logger=zap \
    --log-level=warn \
    > /tmp/etcd-${name}.log 2>&1 &" &
done
wait
sleep 3

echo "[etcd] checking liveness..."
for i in "${!IPS[@]}"; do
  ip="${IPS[$i]}"
  name="${NAMES[$i]}"
  if ssh -o ConnectTimeout=3 "ztang@$ip" "\$HOME/.local/bin/etcdctl --endpoints=http://${ip}:2379 endpoint health" 2>&1 | head -1 | grep -q "is healthy"; then
    echo "  ${name}: healthy"
  else
    echo "  ${name}: UNHEALTHY"
    ssh "ztang@$ip" "tail -20 /tmp/etcd-${name}.log" 2>&1 | sed "s/^/    /"
  fi
done
