bash batch_op.sh kill_mongod

CMD=/home/ubuntu/JetPack/JetPack-Scripts/bin/mongod

servers=(
  "184.72.49.232"
  "44.225.32.130"
  "3.6.253.80"
  "18.198.73.192"
  "16.171.74.27"
)

for idx in "${!servers[@]}"; do
  ip="${servers[$idx]}"
  rs_id=$((idx + 1))
  bind_ip="0.0.0.0"
  ssh "$ip" "mkdir -p /data/rs${rs_id} /var/log/mongodb/rs${rs_id} && $CMD --replSet rsTest --port 27017 --bind_ip ${bind_ip} --dbpath /data/rs${rs_id} --logpath /var/log/mongodb/rs${rs_id}/mongod.log --fork"
  sleep 1
done

sleep 1

ps aux | grep '[m]ongod'

# bash -x reset_mongodb.sh || ps aux | grep '[m]ongod' 
# mongosh --host 127.0.0.1 --port 27017
# pkill -f "mongod.*--port 27017.*--bind_ip 127.0.0.1"
