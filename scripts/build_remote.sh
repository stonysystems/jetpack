#!/bin/bash
# Build janus on the current machine from repo root
REPO=/home/users/ztang/janus
exec python3 "$REPO/waf" --top="$REPO" --out="$REPO/build" configure build 2>&1
