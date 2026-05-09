#!/usr/bin/env bash
# ae/aws/camera-ready/run.sh — One-click driver for the camera-ready
# AWS reproduction matrix. Implements the recipe described in this
# directory's settings.md.
#
# Usage:
#   ./run.sh                # full matrix: exp 0 → derive fixed conc → exp 1,2
#   ./run.sh --exp 0        # exp 0 only
#   ./run.sh --exp 1,2      # exp 1 + 2 only (assumes fixed concs already set)
#   ./run.sh --skip-build
#   ./run.sh --dry-run
#
# Output: ae/output/aws_<timestamp>/
# Caller: ae/aws/run.sh delegates here.

set -euo pipefail

CR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # ae/aws/camera-ready/
AWS_DIR="$(cd "$CR_DIR/.." && pwd)"                        # ae/aws/
AE_DIR="$(cd "$AWS_DIR/.." && pwd)"                        # ae/
SCRIPTS="$AWS_DIR/scripts"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-${AE_DIR}/output/aws_${TIMESTAMP}}"

EXPS="0,1,2"
SKIP_BUILD=false
DRY_RUN=false

log_info()  { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }
log_error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }
log_step()  { echo ""; echo "====== $* ======"; echo ""; }
run_cmd() {
    if $DRY_RUN; then echo "  [DRY-RUN] $*"; else "$@"; fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --exp)         EXPS="$2"; shift 2 ;;
        --skip-build)  SKIP_BUILD=true; shift ;;
        --output)      OUTPUT_DIR="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --help|-h)     sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)             log_error "Unknown arg: $1"; exit 1 ;;
    esac
done

mkdir -p "$OUTPUT_DIR"
log_info "Camera-ready run started"
log_info "Output:      $OUTPUT_DIR"
log_info "Experiments: $EXPS"
log_info "Skip build:  $SKIP_BUILD"

# ---------------------------------------------------------------------------
# Backend cluster lifecycle helpers
# ---------------------------------------------------------------------------

start_backend() {
    local backend="$1"
    log_info "Starting $backend cluster on AWS"
    case "$backend" in
        mongodb)
            ( cd "$SCRIPTS" && run_cmd ./start_mongodb_cluster.sh ) \
                2>&1 | tee "$OUTPUT_DIR/start_${backend}.log"
            ;;
        etcd)
            ( cd "$SCRIPTS" && run_cmd ./start_etcd_cluster_aws.sh ) \
                2>&1 | tee "$OUTPUT_DIR/start_${backend}.log"
            ;;
        zookeeper)
            # No start_zookeeper_cluster.sh in the frozen scripts copy yet;
            # zookeeper cluster lifecycle is TODO upstream. Skip-and-warn.
            log_warn "zookeeper cluster start is TODO — assuming already running"
            ;;
        *)
            log_warn "Unknown backend: $backend"; return 1 ;;
    esac
}

stop_backend() {
    local backend="$1"
    log_info "Stopping $backend cluster"
    case "$backend" in
        mongodb)
            ( cd "$SCRIPTS" && run_cmd ./stop_mongodb_cluster.sh ) \
                2>&1 | tee "$OUTPUT_DIR/stop_${backend}.log" || true
            ;;
        etcd)
            ( cd "$SCRIPTS" && run_cmd ./stop_etcd_cluster_aws.sh ) \
                2>&1 | tee "$OUTPUT_DIR/stop_${backend}.log" || true
            ;;
        zookeeper)
            log_warn "zookeeper cluster stop is TODO upstream"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Build phase
# ---------------------------------------------------------------------------
phase_build() {
    if $SKIP_BUILD; then log_info "Skipping build"; return 0; fi
    log_step "Phase: build (server0, NFS-shared)"
    ( cd "$SCRIPTS" && run_cmd ./10-run_all.sh build ) \
        2>&1 | tee "$OUTPUT_DIR/build.log" || {
        log_error "Build failed; see $OUTPUT_DIR/build.log"; return 1;
    }
}

# ---------------------------------------------------------------------------
# Exp 0 — concurrency sweep
# ---------------------------------------------------------------------------
phase_exp0() {
    log_step "Phase: exp 0 (concurrency sweep, all 9 protocols)"
    # Backend protocols (etcd/mongodb/zookeeper) need their service running.
    # Per-family lifecycle: start once before each family, stop after.
    for backend in mongodb etcd zookeeper; do
        start_backend "$backend"
    done
    ( cd "$SCRIPTS" && run_cmd ./10-run_all.sh --exp 0 ) \
        2>&1 | tee "$OUTPUT_DIR/exp0.log" || \
        log_warn "exp 0 reported failures; check log"
    for backend in zookeeper etcd mongodb; do
        stop_backend "$backend"
    done

    # Refresh fixed concurrencies from exp 0 results.
    log_info "Refreshing LEGACY_FIXED_CONCS via derive_fixed_conc.py"
    ( cd "$SCRIPTS" && run_cmd python3 ./derive_fixed_conc.py ) || \
        log_warn "derive_fixed_conc failed; continuing with current LEGACY_FIXED_CONCS"
}

# ---------------------------------------------------------------------------
# Exp 1 — Zipf sweep
# ---------------------------------------------------------------------------
phase_exp1() {
    log_step "Phase: exp 1 (Zipf sweep at fixed conc)"
    for backend in mongodb etcd zookeeper; do
        start_backend "$backend"
    done
    ( cd "$SCRIPTS" && run_cmd ./10-run_all.sh --exp 1 ) \
        2>&1 | tee "$OUTPUT_DIR/exp1.log" || \
        log_warn "exp 1 reported failures; check log"
    for backend in zookeeper etcd mongodb; do
        stop_backend "$backend"
    done
}

# ---------------------------------------------------------------------------
# Exp 2 — key-range sweep
# ---------------------------------------------------------------------------
phase_exp2() {
    log_step "Phase: exp 2 (key-range sweep at fixed conc)"
    for backend in mongodb etcd zookeeper; do
        start_backend "$backend"
    done
    ( cd "$SCRIPTS" && run_cmd ./10-run_all.sh --exp 2 ) \
        2>&1 | tee "$OUTPUT_DIR/exp2.log" || \
        log_warn "exp 2 reported failures; check log"
    for backend in zookeeper etcd mongodb; do
        stop_backend "$backend"
    done
}

# ---------------------------------------------------------------------------
# Figure / table generation
# ---------------------------------------------------------------------------
phase_figures() {
    log_step "Phase: figures + tables"
    local figdir="$OUTPUT_DIR/figures"
    mkdir -p "$figdir"

    # Consolidated CSV from all .res files
    if [[ -x "$SCRIPTS/build_consolidated_csv.sh" ]]; then
        ( cd "$SCRIPTS" && run_cmd ./build_consolidated_csv.sh "$OUTPUT_DIR" "$OUTPUT_DIR/consolidated.csv" ) \
            2>&1 | tee "$OUTPUT_DIR/consolidate.log" || true
    fi

    # Per-protocol summary tables
    if [[ -x "$SCRIPTS/build_per_protocol_tables.py" ]]; then
        ( cd "$SCRIPTS" && run_cmd python3 ./build_per_protocol_tables.py \
            --input "$OUTPUT_DIR" --output "$figdir" ) || true
    fi

    # Camera-ready figures from the in-tree generators
    for gen in gen_tput_p90_figures.py gen_workload_axis_figures.py gen_latency_cdf.py; do
        if [[ -f "$CR_DIR/$gen" ]]; then
            log_info "Running $gen"
            ( cd "$CR_DIR" && run_cmd python3 "$gen" --out "$figdir" ) \
                2>&1 | tee "$OUTPUT_DIR/$gen.log" || \
                log_warn "$gen failed; check log"
        fi
    done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
phase_summary() {
    local sum="$OUTPUT_DIR/SUMMARY.md"
    {
        echo "# Camera-ready AWS reproduction summary"
        echo ""
        echo "- Started: $TIMESTAMP"
        echo "- Output:  \`$OUTPUT_DIR\`"
        echo "- Exps:    $EXPS"
        echo ""
        echo "## Per-experiment logs"
        for f in build.log exp0.log exp1.log exp2.log; do
            [[ -f "$OUTPUT_DIR/$f" ]] && echo "- \`$f\`"
        done
        echo ""
        echo "## Backend lifecycle logs"
        for f in start_*.log stop_*.log; do
            [[ -f "$OUTPUT_DIR/$f" ]] && echo "- \`$(basename "$f")\`"
        done
        echo ""
        echo "## Figures"
        echo ""
        if [[ -d "$OUTPUT_DIR/figures" ]]; then
            ls "$OUTPUT_DIR/figures" | sed 's|^|- |'
        else
            echo "(no figures generated)"
        fi
        echo ""
        echo "## Output summary"
        echo ""
        echo "Run \`./ae/check_results.sh \"$OUTPUT_DIR\"\` for a sanity summary."
    } > "$sum"
    log_info "Summary: $sum"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
phase_build

if [[ "$EXPS" == *0* ]]; then phase_exp0; fi
if [[ "$EXPS" == *1* ]]; then phase_exp1; fi
if [[ "$EXPS" == *2* ]]; then phase_exp2; fi

phase_figures
phase_summary

log_info "Done. See $OUTPUT_DIR/SUMMARY.md"
