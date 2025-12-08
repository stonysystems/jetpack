#!/usr/bin/env bash

bash batch_op.sh kill_mongod

CMD=/home/ubuntu/code/JetPack/bin/mongod

servers=(
  "184.72.49.232"
  "44.225.32.130"
  "3.6.253.80"
  "18.198.73.192"
  "16.171.74.27"
)

start_all=$SECONDS

for idx in "${!servers[@]}"; do
  ip="${servers[$idx]}"
  rs_id=$((idx + 1))
  bind_ip="0.0.0.0"

  (
    start_one=$SECONDS
    echo "[$ip] starting mongod for rs${rs_id}..."

    ssh "$ip" "mkdir -p /tmp/rs${rs_id} /tmp/log/mongodb/rs${rs_id} && \
      $CMD --replSet rsTest --port 27017 --bind_ip ${bind_ip} \
           --dbpath /tmp/rs${rs_id} \
           --logpath /tmp/log/mongodb/rs${rs_id}/mongod.log --fork"

    elapsed_one=$((SECONDS - start_one))
    echo "[$ip] done in ${elapsed_one}s"
    sleep 1
  ) &
done

# wait for all background jobs (all ssh calls) to finish
wait

elapsed_all=$((SECONDS - start_all))
echo "All servers started in ${elapsed_all}s"


sleep 1

ps aux | grep '[m]ongod'

# bash -x reset_mongodb.sh || ps aux | grep '[m]ongod' 
# mongosh --host 127.0.0.1 --port 27017
# pkill -f "mongod.*--port 27017.*--bind_ip 127.0.0.1"
