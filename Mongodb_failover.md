## Implementation of MongoDb on Ubuntu22.04

The critical changes :

1. Trigger a failure 

   Pause from JetPack, but we should kill the leader MongoDb leader instance

2. Mongodb_connection _thread_pool

   It’s unnecessary, weird and makes evaluation complicated; we create too many threads (2000s) and then each one have a queue to process a request!

   `void MongodbHandler(int thread_id)` do the work!

3. Jetpack → forward requests to the underlying MongoDb
   
   Current implementation has fixed leader, but we should implement a forward semantics

4. Jetpack waits on a signal 

   When MongoDb a new leader elected, send a signal via file

   TODO: impelment an util c++ header that can be included by JetPack and us

5. MongoDb waits for a signal from Jetpack

   When Jetpack finishes its leader election, send a signal back to the MongoDb 

6. MongoDb new leader election


## Implementation

Add a flag: `JETPACK_MONGODB_RECOVERY`

## Code pieces

`TxLogServer::JetpackStatus::RECOVERY`: status

## Install Mongodb official
```bash
curl -fsSL https://pgp.mongodb.com/server-7.0.asc | \
  sudo gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor

echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | \
  sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list

sudo apt update
sudo apt install -y mongodb-org
sudo systemctl start mongod
sudo systemctl status mongod

# 5 ip setup
sudo mkdir -p /data/rs{1,2,3,4,5}
sudo mkdir -p /var/log/mongodb/rs{1,2,3,4,5}
sudo chown -R "$USER":"$USER" /data/rs* /var/log/mongodb/rs*

mongod --replSet rsTest --port 27017 \
  --bind_ip 127.0.0.1 \
  --dbpath /data/rs1 \
  --logpath /var/log/mongodb/rs1/mongod.log \
  --fork

mongod --replSet rsTest --port 27017 \
  --bind_ip 127.0.0.2 \
  --dbpath /data/rs2 \
  --logpath /var/log/mongodb/rs2/mongod.log \
  --fork

mongod --replSet rsTest --port 27017 \
  --bind_ip 127.0.0.3 \
  --dbpath /data/rs3 \
  --logpath /var/log/mongodb/rs3/mongod.log \
  --fork

mongod --replSet rsTest --port 27017 \
  --bind_ip 127.0.0.4 \
  --dbpath /data/rs4 \
  --logpath /var/log/mongodb/rs4/mongod.log \
  --fork

mongod --replSet rsTest --port 27017 \
  --bind_ip 127.0.0.5 \
  --dbpath /data/rs5 \
  --logpath /var/log/mongodb/rs5/mongod.log \
  --fork

ps aux | grep '[m]ongod'

mongosh --host 127.0.0.1 --port 27017

rs.initiate({
  _id: "rsTest",
  members: [
    { _id: 0, host: "127.0.0.1:27017", priority: 1 },
    { _id: 1, host: "127.0.0.2:27017", priority: 0 },
    { _id: 2, host: "127.0.0.3:27017", priority: 0 },
    { _id: 3, host: "127.0.0.4:27017", priority: 0 },
    { _id: 4, host: "127.0.0.5:27017", priority: 0 }
  ]
})

# cfg = rs.conf()
# cfg.members[0].priority = 1 
# cfg.members[1].priority = 0
# cfg.members[2].priority = 0
# cfg.members[3].priority = 0
# cfg.members[4].priority = 0
# rs.reconfig(cfg)

rs.status()

db.adminCommand({getDefaultRWConcern: 1})

# kill
pkill -f 'mongod --replSet rsTest'   # blunt but works for this test setup

```
