pkill -f 'mongod --replSet rsTest' 
ps aux | grep '[m]ongod' 
sleep 1
pkill -f 'mongod --replSet rsTest' 
ps aux | grep '[m]ongod' 
sleep 1
pkill -f 'mongod --replSet rsTest' 
ps aux | grep '[m]ongod' 
sleep 1

mongod --replSet rsTest --port 27017 \
  --bind_ip 127.0.0.1 \
  --dbpath /data/rs1 \
  --logpath /var/log/mongodb/rs1/mongod.log \
  --fork

sleep 1

mongod --replSet rsTest --port 27017 \
  --bind_ip 127.0.0.2 \
  --dbpath /data/rs2 \
  --logpath /var/log/mongodb/rs2/mongod.log \
  --fork

sleep 1

mongod --replSet rsTest --port 27017 \
  --bind_ip 127.0.0.3 \
  --dbpath /data/rs3 \
  --logpath /var/log/mongodb/rs3/mongod.log \
  --fork

sleep 1

mongod --replSet rsTest --port 27017 \
  --bind_ip 127.0.0.4 \
  --dbpath /data/rs4 \
  --logpath /var/log/mongodb/rs4/mongod.log \
  --fork

sleep 1

mongod --replSet rsTest --port 27017 \
  --bind_ip 127.0.0.5 \
  --dbpath /data/rs5 \
  --logpath /var/log/mongodb/rs5/mongod.log \
  --fork

sleep 1

ps aux | grep '[m]ongod'

# bash -x reset_mongodb.sh || ps aux | grep '[m]ongod' 
# mongosh --host 127.0.0.1 --port 27017
