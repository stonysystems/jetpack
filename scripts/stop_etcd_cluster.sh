#!/bin/bash
IPS=(130.245.173.101 130.245.173.102 130.245.173.103 130.245.173.104 130.245.173.105)
for ip in "${IPS[@]}"; do
  ssh -o ConnectTimeout=3 "ztang@$ip" "pkill -9 etcd 2>/dev/null; rm -rf /tmp/etcd-*.etcd" &
done
wait
echo "[etcd] stopped and cleaned on all hosts"
