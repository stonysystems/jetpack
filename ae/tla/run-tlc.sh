#!/bin/bash
# TLC Model Checker Runner for Jetpack TLA+ Specifications
#
# Usage:
#   ./run-tlc.sh <spec> [config] [extra TLC args...]
#
# If <config> is omitted, derives it from <spec>.
# Composition wrappers map to the existing jetpack_* config family
# (e.g., jetpack_raft_composition → jetpack_raft.cfg).
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
# Memory policy:
#   The runner auto-detects total memory and caps TLC to at most 1/3 of that value.
#   - local mode: applies a JVM heap cap with -Xmx
#   - docker mode: applies --memory/--memory-swap plus the same JVM heap cap
# CPU affinity policy:
#   Optional override:
#   - TLC_CPUSET=<cpuset> : CPU set to pin the TLC process/container to
#                           (example: "96-103" or "0,2,4,6")
#   Optional overrides:
#   - TLC_MEMORY_MB=<mb>  : lower or equal total TLC memory budget in MB
#   - TLC_HEAP_MB=<mb>    : lower JVM heap cap in MB within that budget
#
# Examples:
#   # Small-config runs (quick exhaustive check):
#   ./run-tlc.sh jetpack_raft_composition.tla small
#   ./run-tlc.sh jetpack_copilot_composition.tla small
#   ./run-tlc.sh jetpack_mencius_composition.tla small
#
#   # Large-config runs (5 servers / 3 cmds / 2 keys).
#   # The runtime window is defined by the current task docs:
#   # tla/TLA_PLUS_BIG_PICTURE.md and TODO.md.
#   ./run-tlc.sh jetpack_raft_composition.tla
#   ./run-tlc.sh jetpack_copilot_composition.tla
#   ./run-tlc.sh jetpack_mencius_composition.tla
#
#   # Custom config:
#   ./run-tlc.sh jetpack_raft_composition.tla jetpack_raft_custom.cfg -workers 4
#   ./run-tlc.sh jetpack_raft_composition.tla tla/large.cfg -workers 4
#
#   # Force Docker mode:
#   TLC_MODE=docker ./run-tlc.sh jetpack_raft_composition.tla small
#
# Setup (local mode):
#   Download tla2tools.jar v1.7.1 (Java 8 compatible):
#   wget -O tla/tla2tools.jar \
#     https://github.com/tlaplus/tlaplus/releases/download/v1.7.1/tla2tools.jar

set -e

bytes_to_mb() {
    awk -v bytes="$1" 'BEGIN { printf "%d\n", (bytes + 1048575) / 1048576 }'
}

require_positive_integer() {
    case "$2" in
        ''|*[!0-9]*)
            echo "ERROR: $1 must be a positive integer in MB" >&2
            exit 1
            ;;
        *)
            if [ "$2" -le 0 ]; then
                echo "ERROR: $1 must be a positive integer in MB" >&2
                exit 1
            fi
            ;;
    esac
}

detect_local_java_bitness() {
    local java_bin=""
    local java_desc=""

    java_bin=$(command -v java 2>/dev/null || true)
    if [ -z "$java_bin" ] || ! command -v file >/dev/null 2>&1; then
        printf "unknown\n"
        return
    fi

    java_desc=$(file -L "$java_bin" 2>/dev/null || true)
    case "$java_desc" in
        *"32-bit"*)
            printf "32\n"
            ;;
        *"64-bit"*)
            printf "64\n"
            ;;
        *)
            printf "unknown\n"
            ;;
    esac
}

detect_total_memory_mb() {
    local mem_mb=""
    local cgroup_bytes=""

    if command -v awk >/dev/null 2>&1 && [ -r /proc/meminfo ]; then
        mem_mb=$(awk '/MemTotal:/ { printf "%d\n", ($2 + 1023) / 1024; exit }' /proc/meminfo)
    elif command -v sysctl >/dev/null 2>&1; then
        if [ "$(uname -s)" = "Darwin" ]; then
            mem_mb=$(bytes_to_mb "$(sysctl -n hw.memsize)")
        fi
    fi

    if [ -r /sys/fs/cgroup/memory.max ]; then
        cgroup_bytes=$(cat /sys/fs/cgroup/memory.max)
        if [ "$cgroup_bytes" != "max" ] && [ -n "$cgroup_bytes" ]; then
            cgroup_bytes=$(printf "%s" "$cgroup_bytes" | tr -d '[:space:]')
            cgroup_mb=$(bytes_to_mb "$cgroup_bytes")
            if [ -z "$mem_mb" ] || [ "$cgroup_mb" -lt "$mem_mb" ]; then
                mem_mb="$cgroup_mb"
            fi
        fi
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        cgroup_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
        if [ -n "$cgroup_bytes" ]; then
            cgroup_bytes=$(printf "%s" "$cgroup_bytes" | tr -d '[:space:]')
            cgroup_mb=$(bytes_to_mb "$cgroup_bytes")
            if [ -z "$mem_mb" ] || [ "$cgroup_mb" -lt "$mem_mb" ]; then
                mem_mb="$cgroup_mb"
            fi
        fi
    fi

    if [ -z "$mem_mb" ] || [ "$mem_mb" -le 0 ]; then
        echo "ERROR: unable to detect total system memory for TLC cap" >&2
        exit 1
    fi

    printf "%s\n" "$mem_mb"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPEC="$1"
shift || true

if [ -z "$SPEC" ]; then
    echo "Usage: $0 <spec.tla> [config|'small'] [extra TLC args...]"
    echo ""
    echo "Jetpack/base combinations (accepted compositions):"
    echo "  jetpack_raft_composition.tla      - Jetpack + Raft (1 proposer)"
    echo "  jetpack_copilot_composition.tla   - Jetpack + CoPilot (2 proposers)"
    echo "  jetpack_mencius_composition.tla   - Jetpack + Mencius (N proposers)"
    echo ""
    echo "Config options:"
    echo "  (default)  - large config (5 servers, 3 cmds, 2 keys)"
    echo "  small      - small config (3 servers, 1 cmd, 1 key)"
    echo "  <file.cfg> - explicit config file"
    echo "               also accepts paths like tla/large.cfg"
    echo ""
    echo "Environment variables:"
    echo "  TLC_MODE=local   - Use local Java + tla2tools.jar"
    echo "  TLC_MODE=docker  - Use Docker container"
    echo "  TLC_MEMORY_MB    - Lower/equal TLC memory budget in MB (default: auto 1/3 cap)"
    echo "  TLC_HEAP_MB      - Lower JVM heap cap in MB within the TLC memory budget"
    echo ""
    echo "All runs are logged to tla/log/ with timestamp prefix."
    exit 1
fi

SPEC_NAME="${SPEC%.tla}"
CFG_FAMILY="$SPEC_NAME"

case "$SPEC_NAME" in
    jetpack_raft_composition|jetpack_raft_monolithic)
        CFG_FAMILY="jetpack_raft"
        ;;
    jetpack_copilot_composition|jetpack_copilot_monolithic)
        CFG_FAMILY="jetpack_copilot"
        ;;
    jetpack_mencius_composition|jetpack_mencius_monolithic)
        CFG_FAMILY="jetpack_mencius"
        ;;
esac

# Determine config file
CONFIG_ARG="$1"
CONFIG_LABEL=""
CFG=""
CFG_DISPLAY=""
if [ "$CONFIG_ARG" = "small" ]; then
    if [ -f "$SCRIPT_DIR/${SPEC_NAME}_small.cfg" ]; then
        CFG="${SCRIPT_DIR}/${SPEC_NAME}_small.cfg"
    else
        CFG="${SCRIPT_DIR}/${CFG_FAMILY}_small.cfg"
    fi
    CFG_DISPLAY="$(basename "$CFG")"
    CONFIG_LABEL="_small"
    shift || true
elif [ -n "$CONFIG_ARG" ] && [ -f "$SCRIPT_DIR/$CONFIG_ARG" ]; then
    CFG="${SCRIPT_DIR}/$CONFIG_ARG"
    CFG_DISPLAY="$CONFIG_ARG"
    CONFIG_LABEL="_$(basename "${CFG%.cfg}")"
    shift || true
elif [ -n "$CONFIG_ARG" ] && [ -f "$CONFIG_ARG" ]; then
    CFG="$(cd "$(dirname "$CONFIG_ARG")" && pwd)/$(basename "$CONFIG_ARG")"
    CFG_DISPLAY="$CONFIG_ARG"
    CONFIG_LABEL="_$(basename "${CFG%.cfg}")"
    shift || true
elif [ -f "$SCRIPT_DIR/${SPEC_NAME}.cfg" ]; then
    CFG="${SCRIPT_DIR}/${SPEC_NAME}.cfg"
    CFG_DISPLAY="$(basename "$CFG")"
    CONFIG_LABEL=""
elif [ -f "$SCRIPT_DIR/${CFG_FAMILY}.cfg" ]; then
    CFG="${SCRIPT_DIR}/${CFG_FAMILY}.cfg"
    CFG_DISPLAY="$(basename "$CFG")"
    CONFIG_LABEL=""
else
    CFG=""
    CFG_DISPLAY=""
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

TOTAL_MEM_MB=$(detect_total_memory_mb)
AUTO_TLC_MEMORY_MB=$((TOTAL_MEM_MB / 3))
if [ "$AUTO_TLC_MEMORY_MB" -lt 256 ]; then
    AUTO_TLC_MEMORY_MB=256
fi

TLC_MEMORY_MB="${TLC_MEMORY_MB:-$AUTO_TLC_MEMORY_MB}"
require_positive_integer "TLC_MEMORY_MB" "$TLC_MEMORY_MB"
if [ "$TLC_MEMORY_MB" -gt "$AUTO_TLC_MEMORY_MB" ]; then
    echo "ERROR: TLC_MEMORY_MB=$TLC_MEMORY_MB exceeds the enforced 1/3 cap of ${AUTO_TLC_MEMORY_MB}MB" >&2
    exit 1
fi

DEFAULT_TLC_HEAP_MB=$((TLC_MEMORY_MB * 90 / 100))
if [ "$DEFAULT_TLC_HEAP_MB" -lt 128 ]; then
    DEFAULT_TLC_HEAP_MB=128
fi
if [ "$DEFAULT_TLC_HEAP_MB" -gt "$TLC_MEMORY_MB" ]; then
    DEFAULT_TLC_HEAP_MB="$TLC_MEMORY_MB"
fi

TLC_HEAP_MB="${TLC_HEAP_MB:-$DEFAULT_TLC_HEAP_MB}"
require_positive_integer "TLC_HEAP_MB" "$TLC_HEAP_MB"
if [ "$TLC_HEAP_MB" -gt "$TLC_MEMORY_MB" ]; then
    echo "ERROR: TLC_HEAP_MB=$TLC_HEAP_MB exceeds TLC_MEMORY_MB=$TLC_MEMORY_MB" >&2
    exit 1
fi

LOCAL_JAVA_BITS="unknown"
LOCAL_JAVA_HEAP_MAX_MB=""
LOCAL_JAVA_HEAP_CLAMPED="no"
EFFECTIVE_TLC_MEMORY_MB="$TLC_MEMORY_MB"

if [ "$TLC_MODE" = "local" ]; then
    LOCAL_JAVA_BITS=$(detect_local_java_bitness)
    if [ "$LOCAL_JAVA_BITS" = "32" ]; then
        LOCAL_JAVA_HEAP_MAX_MB=1408
        if [ "$TLC_HEAP_MB" -gt "$LOCAL_JAVA_HEAP_MAX_MB" ]; then
            TLC_HEAP_MB="$LOCAL_JAVA_HEAP_MAX_MB"
            LOCAL_JAVA_HEAP_CLAMPED="yes"
        fi
    fi
    if [ "$TLC_HEAP_MB" -lt "$EFFECTIVE_TLC_MEMORY_MB" ]; then
        EFFECTIVE_TLC_MEMORY_MB="$TLC_HEAP_MB"
    fi
fi

JAVA_HEAP_ARG="-Xmx${TLC_HEAP_MB}m"

# Create log directory
mkdir -p "$SCRIPT_DIR/log"

# Generate timestamp-prefixed log filename
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOGFILE="$SCRIPT_DIR/log/${TIMESTAMP}_${SPEC_NAME}${CONFIG_LABEL}.log"

echo "=== TLC Run ===" | tee "$LOGFILE"
echo "Spec:      $SPEC" | tee -a "$LOGFILE"
echo "Config:    ${CFG_DISPLAY:-none}" | tee -a "$LOGFILE"
echo "Mode:      $TLC_MODE" | tee -a "$LOGFILE"
echo "Detected total memory: ${TOTAL_MEM_MB}MB" | tee -a "$LOGFILE"
echo "Auto 1/3 memory cap: ${AUTO_TLC_MEMORY_MB}MB" | tee -a "$LOGFILE"
echo "Configured TLC memory cap: ${TLC_MEMORY_MB}MB" | tee -a "$LOGFILE"
if [ -n "${TLC_CPUSET:-}" ]; then
    echo "Configured TLC cpuset: ${TLC_CPUSET}" | tee -a "$LOGFILE"
fi
if [ "$TLC_MODE" = "local" ]; then
    echo "Local Java bitness: ${LOCAL_JAVA_BITS}" | tee -a "$LOGFILE"
    if [ -n "$LOCAL_JAVA_HEAP_MAX_MB" ]; then
        echo "Local 32-bit JVM heap ceiling: ${LOCAL_JAVA_HEAP_MAX_MB}MB" | tee -a "$LOGFILE"
    fi
    if [ "$LOCAL_JAVA_HEAP_CLAMPED" = "yes" ]; then
        echo "Adjusted JVM heap cap for local Java: ${TLC_HEAP_MB}MB" | tee -a "$LOGFILE"
    fi
fi
echo "Enforced TLC memory cap: ${EFFECTIVE_TLC_MEMORY_MB}MB" | tee -a "$LOGFILE"
echo "JVM heap cap: ${TLC_HEAP_MB}MB" | tee -a "$LOGFILE"
echo "Log:       $LOGFILE" | tee -a "$LOGFILE"
echo "Started:   $(date -Iseconds)" | tee -a "$LOGFILE"
echo "===============" | tee -a "$LOGFILE"

# Assemble TLC arguments
TLC_ARGS=()
if [ -n "$CFG" ] && [ -f "$CFG" ]; then
    TLC_ARGS+=("-config" "$CFG")
    echo "Using config: $CFG_DISPLAY" | tee -a "$LOGFILE"
    echo "--- Config contents ---" >> "$LOGFILE"
    cat "$CFG" >> "$LOGFILE"
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
    JAVA_CMD=(java "$JAVA_HEAP_ARG" -cp tla2tools.jar tlc2.TLC -nowarning -deadlock "${TLC_ARGS[@]}")
    if [ -n "${TLC_CPUSET:-}" ]; then
        taskset -c "$TLC_CPUSET" "${JAVA_CMD[@]}" 2>&1 | tee -a "$LOGFILE"
    else
        "${JAVA_CMD[@]}" 2>&1 | tee -a "$LOGFILE"
    fi
elif [ "$TLC_MODE" = "docker" ]; then
    echo "Building Docker image..." | tee -a "$LOGFILE"
    docker build -t tlaplus "$SCRIPT_DIR" >> "$LOGFILE" 2>&1
    DOCKER_CMD=(docker run --rm --privileged)
    if [ -n "${TLC_CPUSET:-}" ]; then
        DOCKER_CMD+=(--cpuset-cpus "$TLC_CPUSET")
    fi
    DOCKER_CMD+=(
        --memory "${TLC_MEMORY_MB}m"
        --memory-swap "${TLC_MEMORY_MB}m"
        -e "JAVA_TOOL_OPTIONS=${JAVA_HEAP_ARG}"
        -v "$SCRIPT_DIR":/tla
        tlaplus
        tlc2.TLC -nowarning -deadlock "${TLC_ARGS[@]}"
    )
    "${DOCKER_CMD[@]}" 2>&1 | tee -a "$LOGFILE"
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
