#!/bin/bash
# gen_client_config.sh — emit Nc1s5r5p-zoo.yml with N clients uniformly
# distributed across zoo1..zoo5. Writes to config/${N}c1s5r5p-zoo.yml; no-op
# if the file already exists (callers can rerun safely).
#
# Usage: ./gen_client_config.sh <N>

set -euo pipefail

N="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$REPO_DIR/config/${N}c1s5r5p-zoo.yml"

if [ -f "$OUT" ]; then
  exit 0
fi

# Pad client ids to width 2 (c01..c99) when N<100, width 3 otherwise, to
# match the format used by the existing 30c/100c configs.
if [ "$N" -lt 100 ]; then
  WIDTH=2
else
  WIDTH=3
fi

cids=()
for i in $(seq 1 "$N"); do
  cids+=("c$(printf "%0${WIDTH}d" "$i")")
done

{
  echo ""
  echo "site:"
  echo "  server: # each line is a partition, the first is the master site_name:port"
  echo "    - [\"s101:38000\", \"s201:38001\", \"s301:38002\", \"s401:38003\", \"s501:38004\"]"
  echo "  client: # each line is a partition"
  printf "    - ["
  # break every 5 entries per line to keep it readable
  for idx in "${!cids[@]}"; do
    if [ $((idx % 5)) -eq 0 ] && [ "$idx" -gt 0 ]; then
      printf "\n       "
    fi
    printf "\"%s\"" "${cids[$idx]}"
    if [ "$idx" -lt $((${#cids[@]} - 1)) ]; then
      printf ", "
    fi
  done
  echo "]"
  echo ""
  echo ""
  echo "process:"
  echo "  s101: zoo1"
  echo "  s201: zoo2"
  echo "  s301: zoo3"
  echo "  s401: zoo4"
  echo "  s501: zoo5"
  for idx in "${!cids[@]}"; do
    # Uniformly round-robin across zoo1..zoo5.
    zoo_idx=$(( idx % 5 + 1 ))
    echo "  ${cids[$idx]}: zoo${zoo_idx}"
  done
  echo ""
  echo "host:"
  echo "  zoo1: 130.245.173.101"
  echo "  zoo2: 130.245.173.102"
  echo "  zoo3: 130.245.173.103"
  echo "  zoo4: 130.245.173.104"
  echo "  zoo5: 130.245.173.105"
} > "$OUT"
