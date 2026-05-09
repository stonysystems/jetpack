#!/usr/bin/env bash
# Rewrite `host:` IP entries in JetPack/config/*.yml to match the current
# Elastic IPs in aws_instances.tsv. The configs are NFS-shared from SERVER_0,
# so this runs once on SERVER_0.
#
# Old → new mapping is driven by server index (server0..server9). The old IPs
# left over from a previous deployment are listed in OLD_IPS below; if you
# launch a new cluster, update both OLD_IPS (from `git diff aws_instances.tsv`)
# and aws_instances.tsv before running.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVENTORY="${SCRIPT_DIR}/aws_instances.tsv"

# Old EIPs from the previous deployment (committed in the JetPack config files).
declare -a OLD_IPS=(
  "184.72.49.232"   # server0 California
  "44.225.32.130"   # server1 Oregon
  "3.6.253.80"      # server2 Mumbai
  "18.198.73.192"   # server3 Frankfurt
  "16.171.74.27"    # server4 Stockholm
  "35.179.49.225"   # server5 London
  "16.163.96.221"   # server6 Hong Kong
  "3.1.129.2"       # server7 Singapore
  "108.129.57.113"  # server8 Ireland
  "35.181.118.171"  # server9 Paris
)

# New EIPs (from aws_instances.tsv, indexed by server number).
declare -a NEW_IPS
while IFS=$'\t' read -r idx city region instance_id eip; do
  [[ -z "$idx" || "$idx" == \#* ]] && continue
  NEW_IPS+=("$eip")
done < "$INVENTORY"

if [[ ${#NEW_IPS[@]} -ne ${#OLD_IPS[@]} ]]; then
    echo "Error: ${#OLD_IPS[@]} old IPs but ${#NEW_IPS[@]} new IPs in $INVENTORY"
    exit 1
fi

# Build a single sed expression that does all 10 substitutions.
SED_EXPR=""
for i in "${!OLD_IPS[@]}"; do
    old="${OLD_IPS[$i]}"
    new="${NEW_IPS[$i]}"
    # Escape dots in the search pattern.
    old_escaped="${old//./\\.}"
    SED_EXPR+="s/${old_escaped}/${new}/g; "
    echo "  server$i: $old -> $new"
done

# Read SERVER_0 IP from setup.json (cd to scripts/ for relative path).
cd "$SCRIPT_DIR"
SERVER_0_IP=$(jq -r '.servers[0].server_0_ip' setup.json)
if [[ -z "$SERVER_0_IP" || "$SERVER_0_IP" == "null" ]]; then
    echo "Error: server_0_ip not found in setup.json. Run 00-ips.sh first."
    exit 1
fi

echo ""
echo "Updating config IPs on SERVER_0 ($SERVER_0_IP)..."
ssh "ubuntu@$SERVER_0_IP" "
set -e
cd /home/ubuntu/code/JetPack/config
files=\$(grep -lE '$( IFS='|'; echo "${OLD_IPS[*]//./\\.}")' *.yml 2>/dev/null || true)
if [[ -z \"\$files\" ]]; then
    echo 'No config files contain the old IPs; nothing to do.'
    exit 0
fi
echo \"Files to update:\"
echo \"\$files\" | sed 's/^/  /'
for f in \$files; do
    sed -i.bak '$SED_EXPR' \"\$f\"
done
echo 'Done.'
"
