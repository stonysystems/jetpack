#!/bin/bash
# TLC Model Checker Runner for Jetpack TLA+ Specifications
#
# Usage:
#   ./run-tlc.sh <spec> [config] [extra TLC args...]
#
# If <config> is omitted, derives it from <spec> (e.g., jetpack_raft → jetpack_raft.cfg).
# If <config> is "small", uses <spec_name>_small.cfg instead.
#
# All output is saved to tla/log/ with a timestamp-prefixed filename:
#   log/<YYYYMMDD_HHMMSS>_<spec_name>[_<config_label>].log
#
# Execution modes (auto-detected, or override with environment variable):
#   TLC_MODE=local   - Use local Java + tla2tools.jar (requires Java 8+ and tla2tools.jar)
#   TLC_MODE=docker  - Use Docker container (requires Docker)
#   (default)        - Auto-detect: local if tla2tools.jar exists, else Docker
#
# Examples:
#   # Small-config runs (quick exhaustive check):
#   ./run-tlc.sh jetpack_raft.tla small
#   ./run-tlc.sh jetpack_copilot.tla small
#   ./run-tlc.sh jetpack_mencius.tla small
#
#   # Big-config runs (12-hour verification, 5 servers / 3 cmds / 2 keys):
#   ./run-tlc.sh jetpack_raft.tla
#   ./run-tlc.sh jetpack_copilot.tla
#   ./run-tlc.sh jetpack_mencius.tla
#
#   # Custom config:
#   ./run-tlc.sh jetpack_raft.tla jetpack_raft_custom.cfg -workers 4
#
#   # Force Docker mode:
#   TLC_MODE=docker ./run-tlc.sh jetpack_raft.tla small
#
# Setup (local mode):
#   Download tla2tools.jar v1.7.1 (Java 8 compatible):
#   wget -O tla/tla2tools.jar \
#     https://github.com/tlaplus/tlaplus/releases/download/v1.7.1/tla2tools.jar

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPEC="$1"
shift || true

if [ -z "$SPEC" ]; then
    echo "Usage: $0 <spec.tla> [config|'small'] [extra TLC args...]"
    echo ""
    echo "Jetpack/base combinations (accepted compositions):"
    echo "  jetpack_raft.tla      - Jetpack + Raft (1 proposer)"
    echo "  jetpack_copilot.tla   - Jetpack + CoPilot (2 proposers)"
    echo "  jetpack_mencius.tla   - Jetpack + Mencius (N proposers)"
    echo ""
    echo "Config options:"
    echo "  (default)  - big config (5 servers, 3 cmds, 2 keys)"
    echo "  small      - small config (3 servers, 1 cmd, 1 key)"
    echo "  <file.cfg> - explicit config file"
    echo ""
    echo "Environment variables:"
    echo "  TLC_MODE=local   - Use local Java + tla2tools.jar"
    echo "  TLC_MODE=docker  - Use Docker container"
    echo ""
    echo "All runs are logged to tla/log/ with timestamp prefix."
    exit 1
fi

SPEC_NAME="${SPEC%.tla}"

# Determine config file
CONFIG_ARG="$1"
CONFIG_LABEL=""
if [ "$CONFIG_ARG" = "small" ]; then
    CFG="${SPEC_NAME}_small.cfg"
    CONFIG_LABEL="_small"
    shift || true
elif [ -n "$CONFIG_ARG" ] && [ -f "$SCRIPT_DIR/$CONFIG_ARG" ]; then
    CFG="$CONFIG_ARG"
    CONFIG_LABEL="_$(basename "${CFG%.cfg}")"
    shift || true
elif [ -f "$SCRIPT_DIR/${SPEC_NAME}.cfg" ]; then
    CFG="${SPEC_NAME}.cfg"
    CONFIG_LABEL=""
else
    CFG=""
fi

# Determine execution mode
if [ -z "$TLC_MODE" ]; then
    if [ -f "$SCRIPT_DIR/tla2tools.jar" ]; then
        TLC_MODE="local"
    elif command -v docker &>/dev/null; then
        TLC_MODE="docker"
    else
        echo "ERROR: Neither tla2tools.jar nor Docker found."
        echo "  Local mode: download tla2tools.jar v1.7.1 into tla/"
        echo "  Docker mode: install Docker"
        exit 1
    fi
fi

# Create log directory
mkdir -p "$SCRIPT_DIR/log"

# Generate timestamp-prefixed log filename
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOGFILE="$SCRIPT_DIR/log/${TIMESTAMP}_${SPEC_NAME}${CONFIG_LABEL}.log"

echo "=== TLC Run ===" | tee "$LOGFILE"
echo "Spec:      $SPEC" | tee -a "$LOGFILE"
echo "Config:    ${CFG:-none}" | tee -a "$LOGFILE"
echo "Mode:      $TLC_MODE" | tee -a "$LOGFILE"
echo "Log:       $LOGFILE" | tee -a "$LOGFILE"
echo "Started:   $(date -Iseconds)" | tee -a "$LOGFILE"
echo "===============" | tee -a "$LOGFILE"

# Assemble TLC arguments
TLC_ARGS=()
if [ -n "$CFG" ] && [ -f "$SCRIPT_DIR/$CFG" ]; then
    TLC_ARGS+=("-config" "$CFG")
    echo "Using config: $CFG" | tee -a "$LOGFILE"
    echo "--- Config contents ---" >> "$LOGFILE"
    cat "$SCRIPT_DIR/$CFG" >> "$LOGFILE"
    echo "--- End config ---" >> "$LOGFILE"
else
    echo "WARNING: No config file found for $SPEC" | tee -a "$LOGFILE"
fi
TLC_ARGS+=("$SPEC")
TLC_ARGS+=("$@")

echo "" | tee -a "$LOGFILE"
echo "Running: tlc2.TLC -nowarning -deadlock ${TLC_ARGS[*]}" | tee -a "$LOGFILE"
echo "" | tee -a "$LOGFILE"

# Run TLC
if [ "$TLC_MODE" = "local" ]; then
    cd "$SCRIPT_DIR"
    java -cp tla2tools.jar tlc2.TLC -nowarning -deadlock "${TLC_ARGS[@]}" 2>&1 | tee -a "$LOGFILE"
elif [ "$TLC_MODE" = "docker" ]; then
    echo "Building Docker image..." | tee -a "$LOGFILE"
    docker build -t tlaplus "$SCRIPT_DIR" >> "$LOGFILE" 2>&1
    docker run --rm --privileged -v "$SCRIPT_DIR":/tla tlaplus \
        tlc2.TLC -nowarning -deadlock "${TLC_ARGS[@]}" 2>&1 | tee -a "$LOGFILE"
else
    echo "ERROR: Unknown TLC_MODE=$TLC_MODE (must be 'local' or 'docker')" | tee -a "$LOGFILE"
    exit 1
fi

EXIT_CODE=${PIPESTATUS[0]}

echo "" | tee -a "$LOGFILE"
echo "Finished:  $(date -Iseconds)" | tee -a "$LOGFILE"
echo "Exit code: $EXIT_CODE" | tee -a "$LOGFILE"
echo "Log saved: $LOGFILE"

exit $EXIT_CODE
