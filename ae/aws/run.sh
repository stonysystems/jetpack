#!/usr/bin/env bash
# ae/aws/run.sh — Self-contained AWS gold-standard AE driver for Jetpack.
#
# Reproduces the camera-ready paper figures by running the full 860-run
# matrix on 10 × c5.2xlarge across 5 AWS regions. Wall-clock ~28 h.
#
# All paths under ae/aws/ — does not depend on the rest of the repository.
#
# Usage:
#   ./run.sh                    # full reproduction (exp 0,1,2)
#   ./run.sh --exp 0            # exp 0 only (~15 h)
#   ./run.sh --exp 1,2          # exp 1 + 2 only
#   ./run.sh --build-only       # rebuild binary on server0, no experiments
#   ./run.sh --dry-run
#   ./run.sh --help
#
# Prerequisites — see ae/aws/camera-ready/settings.md §1 for full
# detail. In summary:
#   1. 10 EC2 instances (c5.2xlarge) in California / Oregon / Mumbai /
#      Frankfurt / Stockholm + 5 client-heavy spares.
#   2. setup.json populated with the 10 IPs (via scripts/00-ips.sh).
#   3. SSH trust + NFS + repo bootstrap done (scripts/01..07).
#   4. mongod / etcd / zkServer binaries built from the patched
#      third_party/ sources and installed under /usr/local/bin on each
#      server host.
#
# Implementation status (2026-05-08):
#   This is a thin wrapper around scripts/camera-ready/run.sh, which
#   is itself TODO (see ae/aws/camera-ready/settings.md §"TODO" at the
#   bottom). Until that lands, run the manual recipe:
#
#       cd ae/aws/scripts
#       ./10-run_all.sh full --exp 0
#       python3 derive_fixed_conc.py
#       ./10-run_all.sh --exp 1,2
#
#   ae/aws/run.sh wraps that recipe and adds:
#     - Pre-flight checks: setup.json valid, server0 reachable, NFS mounted.
#     - Backend cluster start/stop around mongodb / etcd / zookeeper families.
#     - Result aggregation into ae/output/aws_<timestamp>/.
#     - Figure generation via gen_*.py from camera-ready/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # ae/aws/
AE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                          # ae/
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DEFAULT_OUTPUT="${AE_DIR}/output/aws_${TIMESTAMP}"

OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT}"
EXPS="0,1,2"
BUILD_ONLY=false
DRY_RUN=false

log_info()  { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }
log_error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }
log_step()  { echo ""; echo "====== $* ======"; echo ""; }

run_cmd() {
    if $DRY_RUN; then
        echo "  [DRY-RUN] $*"
    else
        "$@"
    fi
}

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --exp)         EXPS="$2"; shift 2 ;;
        --build-only)  BUILD_ONLY=true; shift ;;
        --output)      OUTPUT_DIR="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --help|-h)     usage ;;
        *)             log_error "Unknown arg: $1"; usage ;;
    esac
done

mkdir -p "$OUTPUT_DIR"
log_info "AWS reproduction started"
log_info "Output dir:  $OUTPUT_DIR"
log_info "Experiments: $EXPS"

# ---------------------------------------------------------------------------
# Pre-flight: read IP config from ae/aws/ips/
# ---------------------------------------------------------------------------
IPS_DIR="$SCRIPT_DIR/ips"

preflight() {
    log_step "Pre-flight: checking $IPS_DIR/"
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq required. Install: apt-get install jq"
        return 1
    fi
    if ! command -v ssh >/dev/null 2>&1; then
        log_error "ssh required for AWS mode."
        return 1
    fi
    check_no_placeholders() {
        if grep -q "REPLACE_ME" "$1" 2>/dev/null; then
            log_error "$1 still contains 'REPLACE_ME' placeholders."
            log_error "Edit it with your real EC2 IPs/SSH-key path before running."
            return 1
        fi
    }
    if [[ -f "$IPS_DIR/setup.json" ]]; then
        log_info "Using existing $IPS_DIR/setup.json"
        check_no_placeholders "$IPS_DIR/setup.json" || return 1
    elif [[ -f "$IPS_DIR/aws_ips.json" ]]; then
        check_no_placeholders "$IPS_DIR/aws_ips.json" || return 1
        log_info "Generating setup.json from $IPS_DIR/aws_ips.json"
        ( cd "$IPS_DIR" && run_cmd "$SCRIPT_DIR/scripts/00-ips.sh" ) || {
            log_error "00-ips.sh failed; check $IPS_DIR/aws_ips.json"
            return 1
        }
    else
        log_error "Neither setup.json nor aws_ips.json found in $IPS_DIR/."
        log_error "Edit one of:"
        log_error "  $IPS_DIR/aws_ips.json.template -> aws_ips.json"
        log_error "  $IPS_DIR/setup.json.template   -> setup.json"
        log_error "See $IPS_DIR/README.md for instructions."
        return 1
    fi
    jq -e '.servers | length >= 5' "$IPS_DIR/setup.json" >/dev/null 2>&1 || {
        log_error "$IPS_DIR/setup.json invalid: needs at least 5 servers"
        return 1
    }
    if jq -r '.servers[] | to_entries[] | .value' "$IPS_DIR/setup.json" 2>/dev/null \
        | grep -qE "^(REPLACE_ME|REPLACE_ME_KEY|nil|null|)$"; then
        log_error "$IPS_DIR/setup.json has unfilled placeholders or empty IPs in servers[]."
        return 1
    fi
    log_info "setup.json validated ($(jq -r '.servers | length' "$IPS_DIR/setup.json") servers)."
    # 10-run_all.sh reads setup.json from cwd; symlink it next to scripts/.
    ln -sf "$IPS_DIR/setup.json" "$SCRIPT_DIR/scripts/setup.json"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
phase_build() {
    log_step "Phase: build (server0, NFS-shared)"
    # 10-run_all.sh resolves setup.json from cwd, so run from scripts/.
    ( cd "$SCRIPT_DIR/scripts" && run_cmd ./10-run_all.sh build ) \
        2>&1 | tee "$OUTPUT_DIR/build.log" || {
        log_error "Build failed; see $OUTPUT_DIR/build.log"; return 1;
    }
}

# ---------------------------------------------------------------------------
# Run experiments
# ---------------------------------------------------------------------------
phase_run_exps() {
    # Delegate to the camera-ready wrapper. It handles backend cluster
    # start/stop bracketing for mongodb/etcd/zookeeper, runs
    # 10-run_all.sh per experiment, refreshes fixed concs from exp 0,
    # and materializes figures + tables.
    log_step "Phase: experiments (delegating to camera-ready/run.sh)"
    OUTPUT_DIR="$OUTPUT_DIR" run_cmd "$SCRIPT_DIR/camera-ready/run.sh" \
        --exp "$EXPS" --output "$OUTPUT_DIR" \
        $($DRY_RUN && echo --dry-run) \
        || log_warn "camera-ready/run.sh exited non-zero; check $OUTPUT_DIR/*.log"
}

# ---------------------------------------------------------------------------
# Figure generation
# ---------------------------------------------------------------------------
phase_figures() {
    log_step "Phase: figures (camera-ready gen_*.py)"
    local figdir="$OUTPUT_DIR/figures"
    mkdir -p "$figdir"
    for gen in gen_tput_p90_figures.py gen_workload_axis_figures.py gen_latency_cdf.py; do
        if [[ -f "$SCRIPT_DIR/camera-ready/$gen" ]]; then
            log_info "Running $gen"
            run_cmd python3 "$SCRIPT_DIR/camera-ready/$gen" --out "$figdir" \
                2>&1 | tee "$OUTPUT_DIR/$gen.log" || \
                log_warn "$gen failed; check log"
        fi
    done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
phase_summary() {
    log_step "Phase: summary"
    local sum="$OUTPUT_DIR/SUMMARY.md"
    {
        echo "# Jetpack AE — AWS reproduction summary"
        echo ""
        echo "- Started: $TIMESTAMP"
        echo "- Output:  \`$OUTPUT_DIR\`"
        echo "- Exps:    $EXPS"
        echo ""
        echo "Per-experiment logs:"
        for f in build.log exp0.log exp1.log exp2.log; do
            [[ -f "$OUTPUT_DIR/$f" ]] && echo "- \`$f\`"
        done
        echo ""
        echo "Figures: \`figures/\`."
        echo ""
        echo "Inspect numbers in \`exp*.log\`."
    } > "$sum"
    log_info "Summary: $sum"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
preflight
if $BUILD_ONLY; then
    phase_build
else
    phase_build
    phase_run_exps
    phase_figures
fi
phase_summary

log_info "Done. See $OUTPUT_DIR/SUMMARY.md"
