#!/bin/bash

# Check if setup.json exists and read values from it
if [ -f "setup.json" ]; then
    environment=$(jq -r '.environment' setup.json)
    N_SERVER=$(jq -r '.n_server' setup.json)
else
    echo "setup.json not found. Try to run \`source 00-ips.sh\`. Exiting."
    exit 1
fi

# If the environment is 'zoo', skip the git clone and .bashrc modification
if [ "$environment" == "zoo" ]; then
    echo "Zoo environment detected. Skipping git clone and .bashrc configuration."
    exit 0
fi

# Proceed with AWS configuration
echo "Proceeding with AWS git clone and .bashrc configuration..."

# --- Prepare SERVER_0 to access private GitHub repo via SSH ---

# Read SERVER_0_IP from setup.json
server_0_ip=$(jq -r '.servers[0].server_0_ip' setup.json)

# 1) Ensure ~/.ssh exists, generate ed25519 key if missing, and prime known_hosts for GitHub
ssh ubuntu@"$server_0_ip" bash <<'EOS'
set -euo pipefail
mkdir -p ~/.ssh && chmod 700 ~/.ssh

# Prefer ed25519; fall back to RSA only if you must
if [ ! -f ~/.ssh/id_ed25519.pub ] && [ ! -f ~/.ssh/id_rsa.pub ]; then
  ssh-keygen -t ed25519 -a 100 -N "" -f ~/.ssh/id_ed25519
fi

# Prime known_hosts so first GitHub contact is non-interactive
# Try standard 22 and SSH-over-HTTPS 443 (for locked-down networks)
ssh-keyscan -H github.com >> ~/.ssh/known_hosts 2>/dev/null || true
ssh-keyscan -H -p 443 ssh.github.com >> ~/.ssh/known_hosts 2>/dev/null || true

# Be explicit about permissions
chmod 600 ~/.ssh/id_* || true
chmod 600 ~/.ssh/known_hosts || true
EOS

# 2) Fetch SERVER_0's public key and show it to the user to add on GitHub
echo
echo "=== SERVER_0 public key (add this to GitHub: Settings → SSH and GPG keys, or as a Deploy Key on the repo) ==="
# Prefer ed25519, otherwise RSA
server0_pub=$(ssh ubuntu@"$server_0_ip" 'test -f ~/.ssh/id_ed25519.pub && cat ~/.ssh/id_ed25519.pub || cat ~/.ssh/id_rsa.pub')
echo "$server0_pub"
echo "=== END PUBLIC KEY ==="
echo

# 3) Verify SERVER_0 can authenticate to GitHub over SSH
# (If this is the first run, expect failure; add the key above to GitHub then re-run.)
# GitHub returns exit code 1 on successful auth banner, 255 on failure.
if ssh -o StrictHostKeyChecking=accept-new -T ubuntu@"$server_0_ip" 'ssh -T git@github.com' 2>&1 | tee /dev/tty | grep -q "successfully authenticated"; then
  echo "GitHub auth looks good."
else
  echo "GitHub auth did not succeed yet. Make sure the exact key above was added to your GitHub account or as the repo's Deploy Key (with write access if you need push)."
  echo "Exiting so you can add the key; rerun this script afterward."
  exit 1
fi


# 4) Clone via SSH (not HTTPS) on SERVER_0
git_clone_cmd='
set -euo pipefail
mkdir -p /home/ubuntu/code
cd /home/ubuntu/code
if [ ! -d "JetPack" ]; then
  git clone git@github.com:MintGreenTZ/JetPack.git
else
  echo "Directory /home/ubuntu/code/JetPack already exists."
fi
'

# Read SERVER_0_IP from setup.json
server_0_ip=$(jq -r '.servers[0].server_0_ip' setup.json)

# Run the git clone command on SERVER_0
ssh ubuntu@"$server_0_ip" "bash -c '$git_clone_cmd'"

# Define an array of server IP addresses dynamically based on N_SERVER
declare -a servers
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)

    # Check if the server IP exists
    if [ "$server_ip" != "null" ] && [ -n "$server_ip" ]; then
        servers+=("${server_ip}")
    else
        echo "Error: IP for server $i is not set or empty in setup.json."
        exit 1
    fi
done

# Line to append to .bashrc
line_to_append="cd /home/ubuntu/code/JetPack"

# Declare an array to keep track of background jobs
declare -a jobs

# Iterate through the list of server IPs and modify .bashrc + aliases in parallel
for server_ip in "${servers[@]}"; do
  (
    ssh ubuntu@"$server_ip" bash << EOF
set -euo pipefail

# 1) Ensure ~/.bashrc has the cd line (idempotent)
if grep -Fxq "$line_to_append" ~/.bashrc; then
  echo "[$server_ip] .bashrc: cd line already exists"
else
  echo "[$server_ip] .bashrc: appending cd line"
  printf "\n%s\n" "$line_to_append" >> ~/.bashrc
fi

# 2) Ensure ~/.bashrc sources ~/.bash_aliases (Ubuntu usually has this; enforce if missing)
if ! grep -qE '(^|;)[[:space:]]*\. ~/.bash_aliases|(^|;)[[:space:]]*source ~/.bash_aliases|\[ -f ~/.bash_aliases \ ] && \.' ~/.bashrc; then
  echo "[$server_ip] .bashrc: adding ~/.bash_aliases source line"
  printf '\n[ -f ~/.bash_aliases ] && . ~/.bash_aliases\n' >> ~/.bashrc
fi

# 3) Create/update ~/.bash_aliases with required aliases (idempotent)
ALIASES_FILE="\$HOME/.bash_aliases"
touch "\$ALIASES_FILE"

# alias rpc_bd
if grep -q '^alias[[:space:]]\+rpc_bd=' "\$ALIASES_FILE"; then
  echo "[$server_ip] alias: rpc_bd already present"
else
  echo "[$server_ip] alias: adding rpc_bd"
  echo 'alias rpc_bd="bin/rpcgen --python --cpp src/deptran/rcc_rpc.rpc"' >> "\$ALIASES_FILE"
fi

# alias bd
if grep -q '^alias[[:space:]]\+bd=' "\$ALIASES_FILE"; then
  echo "[$server_ip] alias: bd already present"
else
  echo "[$server_ip] alias: adding bd"
  echo 'alias bd="python3 waf configure build -J"' >> "\$ALIASES_FILE"
fi

# 4) Permissions (quietly)
chmod 600 "\$ALIASES_FILE" 2>/dev/null || true

EOF
  ) &
  jobs+=($!)
done

# Wait for all background jobs to complete
for job in "${jobs[@]}"; do
  wait "$job"
done

echo "Configured .bashrc and aliases on all servers."

