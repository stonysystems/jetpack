#sudo mkdir -p /data/rs{1,2,3,4,5}
#sudo mkdir -p /var/log/mongodb/rs{1,2,3,4,5}
#sudo chown -R "$USER":"$USER" /data/rs* /var/log/mongodb/rs*
#ls -lh /data/rs*

#sudo tail -n 10 /tmp/JM_*
#sudo ls -lh /data/rs*
#sudo ls -lh /var/log/mongodb/rs*

#bash batch_op.sh kill_mongod
sudo rm -rf /tmp/rs*
sudo rm -rf /tmp/log/mongodb/rs*
sudo mkdir -p /tmp/rs{1,2,3,4,5}
sudo mkdir -p /tmp/log/mongodb/rs{1,2,3,4,5}
sudo chown -R "$USER":"$USER" /tmp/rs* /tmp/log/mongodb/rs*