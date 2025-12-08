while pgrep -f 'mongod --replSet rsTest' > /dev/null; do
  pkill -f 'mongod --replSet rsTest'
  ps aux | grep '[m]ongod'
  sleep 1
done

rm -rf /tmp/rs*/*
rm -rf /tmp/log/mongodb/rs*/*
rm -rf /tmp/JM_*

sleep 1
