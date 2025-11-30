#!/usr/bin/env bash

# List of IPs (edit this list)
IPS=(
  "184.72.49.232"
  "44.225.32.130"
  "3.6.253.80"
  "18.198.73.192"
  "16.171.74.27"
)

# Command dispatcher keyed by op name
op="$1"

CMD="uptime"
case "$op" in
  uptime)      CMD='uptime' ;;
  mongod)      CMD='ps aux | grep mongod' ;;
  op)          CMD='bash ~/JetPack/op.sh' ;;
  kill_mongod) CMD='bash ~/JetPack/kill_mongodb.sh' ;;
esac

if [[ "$op" == "kill_mongod" ]]; then
  echo "Running kill_mongod in parallel..."
  for ip in "${IPS[@]}"; do
    {
      echo "===== $ip ====="
      ssh -o BatchMode=yes -o ConnectTimeout=5 "$ip" "$CMD"
      echo
    } &
  done

  wait
  echo "All kill_mongod jobs finished."
else
  # Default: run sequentially
  for ip in "${IPS[@]}"; do
    echo "===== $ip ====="
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$ip" "$CMD"
    echo
  done
fi
