#!/usr/bin/env bash
# ae/tla/one_click_small.sh
#
# Model-check all 6 Jetpack TLA+ specs on the small (AE-budget)
# configs (3 servers, 2 cmds, 2 keys). Wall-clock ~30 min on 8 cores.
#
# Usage:
#   ./one_click_small.sh           # auto-detect Java + tla2tools.jar
#   TLC_MODE=docker ./one_click_small.sh
#   TLC_MODE=local  ./one_click_small.sh
#
# Output: log/<timestamp>_<spec>_small.log per spec.

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

# Note: raft.tla has no _small.cfg in this archive — only raft.cfg
# exists, which is already the small-scale standalone config (4
# servers / 1 value). It's used here as the "small" Raft run.
SPECS=(
    "raft.tla:raft.cfg"
    "copilot.tla:copilot_small.cfg"
    "mencius.tla:mencius_small.cfg"
    "jetpack_raft_composition.tla:jetpack_raft_small.cfg"
    "jetpack_copilot_composition.tla:jetpack_copilot_small.cfg"
    "jetpack_mencius_composition.tla:jetpack_mencius_small.cfg"
)

mkdir -p log
SUMMARY="log/one_click_small_summary_$(date +%Y%m%d_%H%M%S).md"

{
    echo "# TLA+ small-config run summary"
    echo ""
    echo "| Spec | Config | Status |"
    echo "|---|---|---|"
} > "$SUMMARY"

PASS=0; FAIL=0
for entry in "${SPECS[@]}"; do
    spec="${entry%%:*}"
    cfg="${entry##*:}"
    echo ""
    echo "====== TLC: $spec ($cfg) ======"
    if ./run-tlc.sh "$spec" "$cfg" -workers 4; then
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
    echo "Per-run logs are in \`$(pwd)/log/\`."
} >> "$SUMMARY"

echo ""
echo "Done. Summary: $SUMMARY"
[[ "$FAIL" -eq 0 ]]
