for i in 1 2 3; do
  pkill -f 'mongod --replSet rsTest'
  ps aux | grep '[m]ongod'
  sleep 3
done

CMD=/home/weihai/JetPack/mongo/bazel-bin/install/bin/mongod

for ip in 127.0.0.1 127.0.0.2 127.0.0.3 127.0.0.4 127.0.0.5; do
  $CMD --replSet rsTest --port 27017 \
    --bind_ip $ip \
    --dbpath /data/rs${ip##*.} \
    --logpath /var/log/mongodb/rs${ip##*.}/mongod.log \
    --fork
  sleep 1
done

sleep 1

ps aux | grep '[m]ongod'

# bash -x reset_mongodb.sh || ps aux | grep '[m]ongod' 
# mongosh --host 127.0.0.1 --port 27017
# pkill -f "mongod.*--port 27017.*--bind_ip 127.0.0.1"
