#!/usr/bin/env bash
# ae/tla/one_click_large.sh
#
# Model-check all 6 Jetpack TLA+ specs on the paper-claim configs
# (5 servers, 3 cmds, 2 keys). Wall-clock 12+ h on 16 cores; peak
# RAM ~50 GB. Reproduces the state counts in Tab. 1 of the paper.
#
# Usage:
#   ./one_click_large.sh           # auto-detect Java + tla2tools.jar
#   TLC_MEMORY_MB=32768 ./one_click_large.sh   # cap TLC heap
#
# Output: log/<timestamp>_<spec>.log per spec.

set -euo pipefail
cd "$(dirname "$0")"

# Pre-flight: need either (Java + tla2tools.jar) or Docker.
have_local=false; have_docker=false
command -v java >/dev/null 2>&1 && [[ -f tla2tools.jar ]] && have_local=true
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && have_docker=true
if ! $have_local && ! $have_docker; then
    echo "[ERROR] Need either (Java 8+ and tla2tools.jar) OR Docker." >&2
    echo "        Install one." >&2
    exit 2
fi

# For raft.tla, raft.cfg is the only checked-in config — the
# standalone Raft model is already at moderate scale (4 servers,
# 1 value). Compositions use the "no-suffix" jetpack_*.cfg as the
# paper-claim large config (jetpack_raft_large.cfg also exists for
# extra scale; switch to it manually if you want max state count).
SPECS=(
    "raft.tla:raft.cfg"
    "copilot.tla:copilot.cfg"
    "mencius.tla:mencius.cfg"
    "jetpack_raft_composition.tla:jetpack_raft.cfg"
    "jetpack_copilot_composition.tla:jetpack_copilot.cfg"
    "jetpack_mencius_composition.tla:jetpack_mencius.cfg"
)

mkdir -p log
SUMMARY="log/one_click_large_summary_$(date +%Y%m%d_%H%M%S).md"

{
    echo "# TLA+ large-config run summary (paper claim)"
    echo ""
    echo "| Spec | Config | Status |"
    echo "|---|---|---|"
} > "$SUMMARY"

WORKERS="${TLC_WORKERS:-$(nproc 2>/dev/null || echo 4)}"

PASS=0; FAIL=0
for entry in "${SPECS[@]}"; do
    spec="${entry%%:*}"
    cfg="${entry##*:}"
    echo ""
    echo "====== TLC: $spec ($cfg, workers=$WORKERS) ======"
    if ./run-tlc.sh "$spec" "$cfg" -workers "$WORKERS"; then
        echo "| \`$spec\` | \`$cfg\` | PASS |" >> "$SUMMARY"
        PASS=$((PASS+1))
    else
        echo "| \`$spec\` | \`$cfg\` | FAIL |" >> "$SUMMARY"
        FAIL=$((FAIL+1))
    fi
done

{
    echo ""
    echo "**Result**: $PASS pass / $FAIL fail of ${#SPECS[@]} specs."
    echo ""
    echo "State counts: TLC's final 'N states generated, M distinct' line in each log."
} >> "$SUMMARY"

echo ""
echo "Done. Summary: $SUMMARY"
[[ "$FAIL" -eq 0 ]]
