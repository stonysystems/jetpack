#!/usr/bin/env bash
# Bootstrap script copied to each AWS instance by 02-setup.sh and run there.
# Installs base packages, the three backend services (mongodb / etcd /
# zookeeper) the camera-ready experiments need, plus the per-host config
# pieces required for our deployment topology:
#   - mongod with replSetName=jetpack-rs and bind_ip=0.0.0.0
#   - mongod systemd CPUAffinity=1 (drop-in)
#   - etcd binary at $HOME/.local/bin/etcd (vanilla v3 release)
#   - zookeeper with per-host myid (server0=5, server1=4, …, server4=1)
#     so FastLeaderElection picks server0 on fresh start
#   - zoo.cfg with all 5 ensemble entries + 4lw whitelist
#
# Per-host setup is parameterized by the SERVER_INDEX env var that
# 02-setup.sh passes in (0..N_SERVER-1). Server IPs come in via SERVER_IPS
# (comma-separated). Hosts beyond index 4 (clients-only) skip the
# replica-only steps.
#
# This script is idempotent — re-running on an already-set-up host is safe.
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────
# Parameters from 02-setup.sh
# ─────────────────────────────────────────────────────────────────────────
SERVER_INDEX="${SERVER_INDEX:-}"
SERVER_IPS="${SERVER_IPS:-}"          # comma-separated, ALL hosts in setup.json
N_SERVER="${N_SERVER:-10}"            # total host count

if [[ -z "$SERVER_INDEX" || -z "$SERVER_IPS" ]]; then
    echo "[setup] ERROR: SERVER_INDEX and SERVER_IPS env vars must be set by caller (02-setup.sh)"
    exit 1
fi

# Replicas live on server0..server4. Hosts 5..9 are clients only.
N_REPLICA=5
IFS=',' read -ra IPS <<< "$SERVER_IPS"
S0_IP="${IPS[0]}"

# ─────────────────────────────────────────────────────────────────────────
# 0. Base apt packages (everyone needs these)
# ─────────────────────────────────────────────────────────────────────────
sudo apt-get update --assume-yes
sudo apt-get install --assume-yes \
    nfs-kernel-server nfs-common \
    curl wget jq netcat-openbsd \
    build-essential

cat > ~/.gitconfig <<'EOF'
[user]
	name = MintGreenTZ
	email = mintgreen0529@gmail.com
[color]
	status = auto
	branch = auto
	interactive = auto
	diff = auto
EOF

# Hosts 5..9 are client-only — stop here.
if (( SERVER_INDEX >= N_REPLICA )); then
    echo "[setup] server${SERVER_INDEX} is a client-only host (no backend install)."
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────
# 1. MongoDB: install mongod + replica-set config + CPU affinity drop-in
# ─────────────────────────────────────────────────────────────────────────
echo "[setup] installing mongod..."
if ! command -v mongod >/dev/null 2>&1; then
    # Use Mongo's official apt repo for a recent version that supports
    # readConcern: linearizable (>= 3.4). Ubuntu 22.04 + MongoDB 7.0.
    # Idempotent: if the source list already exists, apt-key add is a no-op.
    curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
        | sudo gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor --yes
    echo "deb [signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" \
        | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list >/dev/null
    sudo apt-get update --assume-yes
    sudo apt-get install --assume-yes mongodb-org
fi

# /etc/mongod.conf needs bind_ip=0.0.0.0 (or all the replica IPs) and
# replSetName=jetpack-rs. Replace the relevant blocks idempotently.
sudo tee /etc/mongod.conf >/dev/null <<EOF
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
net:
  port: 27017
  bindIp: 0.0.0.0
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
replication:
  replSetName: jetpack-rs
EOF

# CPU affinity drop-in: pin mongod main process to core 1, matching the
# deptran server thread.
sudo mkdir -p /etc/systemd/system/mongod.service.d
sudo tee /etc/systemd/system/mongod.service.d/cpuaffinity.conf >/dev/null <<EOF
[Service]
CPUAffinity=1
EOF
sudo systemctl daemon-reload
sudo systemctl enable mongod
sudo systemctl restart mongod
echo "[setup] mongod installed + bound 0.0.0.0:27017 with replSet=jetpack-rs and CPUAffinity=1"

# ─────────────────────────────────────────────────────────────────────────
# 2. etcd: install vanilla v3 release into ~/.local/bin/etcd
# ─────────────────────────────────────────────────────────────────────────
ETCD_VER="v3.5.13"
mkdir -p "$HOME/.local/bin"
if [[ ! -x "$HOME/.local/bin/etcd" ]]; then
    echo "[setup] downloading etcd ${ETCD_VER}..."
    arch=$(dpkg --print-architecture)   # amd64 / arm64
    case "$arch" in
        amd64) etcd_arch="amd64" ;;
        arm64) etcd_arch="arm64" ;;
        *) echo "[setup] unknown arch '$arch' for etcd"; exit 1 ;;
    esac
    tmpd=$(mktemp -d)
    curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-${etcd_arch}.tar.gz" \
        -o "$tmpd/etcd.tar.gz"
    tar -xzf "$tmpd/etcd.tar.gz" -C "$tmpd"
    cp "$tmpd/etcd-${ETCD_VER}-linux-${etcd_arch}/etcd"     "$HOME/.local/bin/etcd"
    cp "$tmpd/etcd-${ETCD_VER}-linux-${etcd_arch}/etcdctl"  "$HOME/.local/bin/etcdctl"
    chmod +x "$HOME/.local/bin/etcd" "$HOME/.local/bin/etcdctl"
    rm -rf "$tmpd"
fi
echo "[setup] etcd at $HOME/.local/bin/etcd ($("$HOME/.local/bin/etcd" --version | head -1))"

# ─────────────────────────────────────────────────────────────────────────
# 3. ZooKeeper: install + per-host myid + ensemble zoo.cfg + 4lw whitelist
# ─────────────────────────────────────────────────────────────────────────
echo "[setup] installing zookeeperd..."
sudo apt-get install --assume-yes zookeeperd

# Map: server0 → myid=5, server1 → 4, server2 → 3, server3 → 2, server4 → 1
# This makes server0 hold the highest sid so ZK FastLeaderElection picks
# it as leader on a fresh-start (equal-ZXID) election.
MY_ID=$(( N_REPLICA - SERVER_INDEX ))   # server0 → 5, …, server4 → 1
sudo mkdir -p /var/lib/zookeeper
echo "$MY_ID" | sudo tee /var/lib/zookeeper/myid >/dev/null
sudo chown -R zookeeper:zookeeper /var/lib/zookeeper 2>/dev/null || true

# Generate zoo.cfg with all 5 ensemble entries (highest-sid → server0).
# Path differs slightly across distros; apt zookeeperd uses /etc/zookeeper/conf/zoo.cfg.
ZOO_CFG="/etc/zookeeper/conf/zoo.cfg"
[[ -d "$(dirname "$ZOO_CFG")" ]] || sudo mkdir -p "$(dirname "$ZOO_CFG")"
{
    echo "tickTime=2000"
    echo "initLimit=10"
    echo "syncLimit=5"
    echo "dataDir=/var/lib/zookeeper"
    echo "clientPort=2181"
    echo "# Fix B (set 2026-05-05): force the leader to fsync the txn log and"
    echo "# replicate to the ZAB-majority before acking. Without these, the"
    echo "# 2026-05-02 ZK runs showed server0 (leader) returning in 0.72 ms"
    echo "# at c=1 — far below R(CA, 2nd-fastest follower) = 149 ms — which"
    echo "# means the leader was acking on its own without waiting for"
    echo "# follower ZAB acks. forceSync=yes makes the leader fsync the txn"
    echo "# log to disk before commit; syncEnabled=yes is the default for"
    echo "# voting members but is set explicitly so the defensive assertion"
    echo "# in start_zookeeper_cluster.sh can verify it on every bring-up."
    echo "forceSync=yes"
    echo "syncEnabled=yes"
    echo "# Four-letter-word whitelist needed by start_zookeeper_cluster.sh's"
    echo "# ruok / srvr liveness + leader checks."
    echo "4lw.commands.whitelist=ruok,srvr,stat,mntr,conf"
    echo "# Highest-sid → server0 (California) so it wins fresh-start election."
    for i in $(seq 0 $((N_REPLICA-1))); do
        sid=$(( N_REPLICA - i ))
        # All 5 nodes are VOTING participants; never use :observer here.
        # The defensive assertion in start_zookeeper_cluster.sh aborts
        # the run if any of these lines acquires :observer (or the count
        # drops below 5) so a future AMI rebake can't silently regress.
        echo "server.${sid}=${IPS[$i]}:2888:3888"
    done
} | sudo tee "$ZOO_CFG" >/dev/null

# (Re)start zookeeper so the new config takes effect. The start_zookeeper_*
# scripts will restart again before each experiment — this just ensures the
# bootstrap state is good.
sudo systemctl enable zookeeper 2>/dev/null || true
sudo systemctl restart zookeeper 2>/dev/null \
    || (sudo /usr/share/zookeeper/bin/zkServer.sh restart 2>/dev/null || true)

echo "[setup] zookeeper installed; myid=${MY_ID}, zoo.cfg has 5-node ensemble + 4lw whitelist"

echo "[setup] server${SERVER_INDEX} bootstrap complete."
