#!/usr/bin/env bash

# Monitor /tmp for JetPack signal files and scp them to other servers
# with at-most-once forwarding per (filename, content) on each server.
#
# Usage:
#   ./monitor_jm_files.sh [self_index] [ssh_user]
#
#   self_index : 0-9 or 00-09 (which server this machine is).
#                If omitted, the script sends to ALL servers (controller mode).
#   ssh_user   : SSH user name (default: ubuntu).

set -u

WATCH_DIR="/tmp"
TARGET_FILES=(
  "JM_Jetpack_failure_triggered"
  "JM_Jetpack_raft_init_election_done"
  "JM_Jetpack_raft_post_failure_election_done"
  "JM_Jetpack_recovery_finish"
  "JM_Jetpack_recovery_finish_after_failure"
)

# IP list, index 0..9
IPS=(
  "184.72.49.232"   # 00 ze-california.pem
  "44.225.32.130"   # 01 ze-oregon.pem
  "3.6.253.80"      # 02 ze-mumbai.pem
  "18.198.73.192"   # 03 ze-frankfurt.pem
  "16.171.74.27"    # 04 ze-stockholm.pem
  "35.179.49.225"   # 05 ze-london.pem
  "16.163.96.221"   # 06 ze-hongkong.pem
  "3.1.129.2"       # 07 ze-singapore.pem
  "108.129.57.113"  # 08 ze-ireland.pem
  "35.181.118.171"  # 09 ze-paris.pem
)

SELF_IDX="${1:-}"
REMOTE_USER="${2:-ubuntu}"

# Normalize SELF_IDX: "00" -> "0"
if [[ -n "$SELF_IDX" && "$SELF_IDX" =~ ^0[0-9]$ ]]; then
  SELF_IDX="${SELF_IDX#0}"
fi

STATE_FILE="/tmp/.jm_jetpack_seen"

# ----- Checks -----

command -v inotifywait >/dev/null 2>&1 || {
  echo "ERROR: inotifywait not found. Install inotify-tools, e.g.:"
  echo "  sudo apt-get update && sudo apt-get install -y inotify-tools"
  exit 1
}

command -v sha256sum >/dev/null 2>&1 || {
  echo "ERROR: sha256sum not found."
  exit 1
}

# ----- State: seen events -----

# Bash associative array mapping event_key -> 1
declare -A SEEN_EVENTS

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    while read -r key; do
      [[ -n "$key" ]] && SEEN_EVENTS["$key"]=1
    done < "$STATE_FILE"
  fi
}

mark_seen() {
  local key="$1"
  SEEN_EVENTS["$key"]=1
  echo "$key" >> "$STATE_FILE"
}

have_seen() {
  local key="$1"
  [[ -n "${SEEN_EVENTS[$key]:-}" ]]
}

# ----- Copy logic -----

copy_to_peers() {
  local path="$1"
  local filename="$2"

  echo "[$(date '+%F %T')] Forwarding $filename from $(hostname)"

  local i ip
  for i in "${!IPS[@]}"; do
    if [[ -n "$SELF_IDX" && "$i" == "$SELF_IDX" ]]; then
      continue
    fi

    ip="${IPS[$i]}"
    echo "  -> ${REMOTE_USER}@${ip}:${WATCH_DIR}/${filename}"

    # If you want per-server keys, change this line to:
    # scp -i /path/to/ze-${i}.pem "$path" "${REMOTE_USER}@${ip}:${WATCH_DIR}/${filename}" &
    scp "$path" "${REMOTE_USER}@${ip}:${WATCH_DIR}/${filename}" &
  done

  wait
  echo "[$(date '+%F %T')] Done forwarding $filename."
}

handle_event() {
  local fullpath="$1"
  local filename
  filename=$(basename "$fullpath")

  # Only care about our three target files
  local ok=0
  for t in "${TARGET_FILES[@]}"; do
    if [[ "$filename" == "$t" ]]; then
      ok=1
      break
    fi
  done
  [[ "$ok" -eq 0 ]] && return

  # File might be gone already (very short-lived)
  if [[ ! -f "$fullpath" ]]; then
    echo "[$(date '+%F %T')] $fullpath disappeared before we could read it; skipping"
    return
  fi

  # Compute event ID = filename + sha256(content)
  local hash
  hash=$(sha256sum "$fullpath" | awk '{print $1}')
  local key="${filename}:${hash}"

  if have_seen "$key"; then
    echo "[$(date '+%F %T')] Already processed event $key; ignoring."
    return
  fi

  # First time we see this event on this server -> mark + forward
  mark_seen "$key"
  copy_to_peers "$fullpath" "$filename"
}

# ----- Main loop -----

load_state

echo "Monitoring ${WATCH_DIR} for JetPack signal files: ${TARGET_FILES[*]}"
if [[ -n "$SELF_IDX" ]]; then
  echo "This machine is server index: ${SELF_IDX}"
else
  echo "SELF_IDX not set: will copy to ALL servers (including itself)."
fi
echo "State file for at-most-once forwarding: ${STATE_FILE}"
echo

# We listen for:
#   - close_write: local process finished writing
#   - moved_to: scp temporary renamed into place
inotifywait -m -e close_write -e moved_to --format '%e %w%f' "$WATCH_DIR" | \
while read -r events fullpath; do
  echo "[$(date '+%F %T')] Event '$events' on $fullpath"
  handle_event "$fullpath"
done
