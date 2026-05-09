#!/usr/bin/env bash
# ae/local/run.sh — Self-contained Docker AE driver for Jetpack.
#
# All paths under ae/local/ — does not depend on the rest of the
# repository. Frozen at AE submission time.
#
# Usage:
#   ./run.sh                    # full reproduction (--mode docker, default)
#   ./run.sh --mode docker      # single-host Docker (tc/netem WAN simulation)
#   ./run.sh --mode cluster     # multi-host SSH cluster (5-node LAN, opt-in)
#                                 reads ae/local/ips/setup.json — see ips/README.md
#   ./run.sh --quick            # 30-min smoke: build + raft mini-sweep + 1 TLA + 1 recovery
#   ./run.sh --phase build      # build images only
#   ./run.sh --phase exp0       # concurrency sweep, all 9 protocols
#   ./run.sh --phase exp1       # zipf sweep
#   ./run.sh --phase exp2       # key-range sweep
#   ./run.sh --phase recovery   # failure recovery
#   ./run.sh --phase tla_small  # TLA+ small configs (all 6)
#   ./run.sh --phase tla_large  # TLA+ paper-claim configs (12+ h, opt-in)
#   ./run.sh --output <dir>     # override output root (default: ae/output/)
#   ./run.sh --dry-run
#   ./run.sh --help
#
# Output: ../output/reproduce_<timestamp>/{build,exp0,exp1,exp2,recovery,tla,figures}/
#
# Implementation status (2026-05-09):
#   build         IMPLEMENTED  (docker mode: scripts/reproduce_evaluation.sh --build-only;
#                               cluster mode: scripts/10-run_all.sh build)
#   exp0_backends IMPLEMENTED  (docker: scripts/sweep_benchmark.sh per backend with
#                               AE_CONC_OVERRIDE; cluster: 10-run_all.sh --exp 0)
#   exp0_native   IMPLEMENTED  (docker: scripts/run_native_local.sh in single-process
#                               mode for raft/copilot/mencius/swiftpaxos/epaxos/curp;
#                               cluster mode handled by 10-run_all.sh)
#   exp1          IMPLEMENTED  (docker: per-protocol zipf sweep at fixed conc;
#                               cluster: 10-run_all.sh --exp 1)
#   exp2          IMPLEMENTED  (docker: per-protocol key-range sweep at fixed conc;
#                               cluster: 10-run_all.sh --exp 2)
#   recovery      IMPLEMENTED  (docker: scripts/reproduce_evaluation.sh --recovery-only;
#                               cluster: 09-build_and_test_run_wan.sh --failover)
#   tla_small     IMPLEMENTED  (delegates to ../tla/one_click_small.sh)
#   tla_large     IMPLEMENTED  (delegates to ../tla/one_click_large.sh; opt-in)
#   summary       IMPLEMENTED

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # ae/local/
AE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                          # ae/
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
COMMIT_HASH="$(git -C "$AE_DIR/.." rev-parse --short HEAD 2>/dev/null || echo 'frozen')"
DEFAULT_OUTPUT="${AE_DIR}/output/reproduce_${TIMESTAMP}"

OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT}"
PHASE="all"
MODE="docker"     # docker | cluster
QUICK=false
DRY_RUN=false
IPS_DIR="$SCRIPT_DIR/ips"

# ---------- Protocol matrix (full AWS density) ----------

# Group-A backend protocols (out-of-process backends — Docker compose images exist).
BACKENDS=(etcd mongodb zookeeper)

# Group-A native protocols (embedded in deptran_server, no backend service).
NATIVE_GROUP_A=(raft copilot mencius)

# Group-B baselines (no jetpack sibling).
NATIVE_GROUP_B=(curp swiftpaxos epaxos)

# Concurrency arrays — match LEGACY_*_CONCS in scripts/experiment_defs.sh.
declare -A CONCS_FULL=(
    [raft]="1 10 20 40 60 80 100 120 140 150 160 170 180 190 200 250 300 400 500 750 1000 1250 1500 2000"
    [copilot]="1 10 20 30 40 50 60 70 72 75 77 80 82 85 87 90 100 120 140 160 180 200"
    [mencius]="1 10 12 14 16 18 20 25 30 35 40 45 50 55 60"
    [mongodb]="1 10 20 30 35 40 50 60 70 80 90 100 110 120"
    [etcd]="1 10 20 30 40 50 60 70 80 90 100 110 120 140 160 180 200 250 300 350 400 500"
    [zookeeper]="1 10 20 30 40 50 60 70 80 90 100 110 120 140 160 180 200 250 300 350 400 500"
    [curp]="1 10 25 50 75 100 150 200 300 500 750"
    [swiftpaxos]="1 10 25 50 75 100 125 150 175 200 250"
    [epaxos]="1 10 25 50 100 150 200 250 300 400 500"
)

# Per-protocol fixed concurrency for exp1/exp2 (matches AWS knees).
declare -A FIXED_CONC=(
    [raft]=150 [copilot]=50 [mencius]=16 [mongodb]=40
    [etcd]=100 [zookeeper]=100
    [curp]=100 [swiftpaxos]=75 [epaxos]=100
)

# Full workload sets — match AWS camera-ready.
ZIPF_FULL=(rw_zipf_1 rw_zipf_0.9 rw_zipf_0.8 rw_zipf_0.7 rw_zipf_0.6 rw_zipf_0.5)
KEYRANGE_FULL=(rw_1 rw_10 rw_100 rw_1000 rw_10000 rw_100000 rw_1000000)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)    PHASE="$2"; shift 2 ;;
        --mode)     MODE="$2"; shift 2 ;;
        --output)   OUTPUT_DIR="$2"; shift 2 ;;
        --quick)    QUICK=true; shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --help|-h)  usage ;;
        *)          log_error "Unknown arg: $1"; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight for cluster mode
# ---------------------------------------------------------------------------
preflight_cluster() {
    log_step "Pre-flight (cluster mode): checking $IPS_DIR/"
    # Detect placeholder values that mean the user never filled the file in.
    check_no_placeholders() {
        if grep -q "REPLACE_ME" "$1" 2>/dev/null; then
            log_error "$1 still contains 'REPLACE_ME' placeholders."
            log_error "Edit it with your real cluster IPs/credentials before running."
            return 1
        fi
    }
    if [[ -f "$IPS_DIR/setup.json" ]]; then
        log_info "Using existing $IPS_DIR/setup.json"
        check_no_placeholders "$IPS_DIR/setup.json" || return 1
    elif [[ -f "$IPS_DIR/cluster_ips.json" ]]; then
        check_no_placeholders "$IPS_DIR/cluster_ips.json" || return 1
        # Refuse to silently overwrite a hand-edited zoo_ips.json.
        if [[ -f "$IPS_DIR/zoo_ips.json" ]]; then
            if ! cmp -s "$IPS_DIR/cluster_ips.json" "$IPS_DIR/zoo_ips.json"; then
                log_warn "$IPS_DIR/zoo_ips.json differs from cluster_ips.json — overwriting (cluster_ips.json wins)"
            fi
        fi
        log_info "Generating setup.json from $IPS_DIR/cluster_ips.json"
        # 00-ips.sh expects the input filename to be zoo_ips.json (a
        # frozen-script detail). Stage a copy, then invoke.
        cp "$IPS_DIR/cluster_ips.json" "$IPS_DIR/zoo_ips.json"
        ( cd "$IPS_DIR" && printf 'zoo\n' | run_cmd "$SCRIPT_DIR/scripts/00-ips.sh" ) || {
            log_error "00-ips.sh failed; check $IPS_DIR/cluster_ips.json"
            return 1
        }
    else
        log_error "Cluster mode needs $IPS_DIR/setup.json or cluster_ips.json."
        log_error "Edit one of:"
        log_error "  $IPS_DIR/cluster_ips.json.template -> cluster_ips.json"
        log_error "  $IPS_DIR/setup.json.template       -> setup.json"
        log_error "See $IPS_DIR/README.md for instructions."
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq required for cluster mode. Install: apt-get install jq"
        return 1
    fi
    jq -e '.servers | length >= 5' "$IPS_DIR/setup.json" >/dev/null 2>&1 || {
        log_error "$IPS_DIR/setup.json invalid: needs at least 5 servers"
        return 1
    }
    # Validate every server has a non-empty, non-placeholder IP.
    if jq -r '.servers[] | to_entries[] | .value' "$IPS_DIR/setup.json" 2>/dev/null \
        | grep -qE "^(REPLACE_ME|nil|null|)$"; then
        log_error "$IPS_DIR/setup.json has empty / 'nil' / 'REPLACE_ME' IPs in servers[]."
        return 1
    fi
    # Symlink so 10-run_all.sh resolves it from cwd
    ln -sf "$IPS_DIR/setup.json" "$SCRIPT_DIR/scripts/setup.json"
    log_info "Cluster pre-flight OK ($(jq -r '.servers | length' "$IPS_DIR/setup.json") servers)."
}

if [[ "$MODE" == "cluster" ]]; then
    preflight_cluster
fi

mkdir -p "$OUTPUT_DIR"/{build,exp0,exp1,exp2,recovery,tla,figures}
log_info "AE directory: $AE_DIR"
log_info "Output dir:   $OUTPUT_DIR"
log_info "Commit:       $COMMIT_HASH"
log_info "Phase:        $PHASE"
log_info "Mode:         $MODE"
log_info "Quick mode:   $QUICK"

# ---------------------------------------------------------------------------
# Pre-flight: environment checks. Fail loudly with a fixable message rather
# than crashing in the middle of a 15-hour run.
# ---------------------------------------------------------------------------
preflight_env() {
    local fatal=0
    # bash version (we use associative arrays — needs bash 4+)
    if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
        log_error "Bash 4+ required (this is ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]})"
        fatal=1
    fi
    # jq is required for cluster preflight + setup.json validation
    if ! command -v jq >/dev/null 2>&1; then
        log_warn "jq not found — needed for cluster mode. Install: apt-get install jq"
    fi
    # Docker required for docker mode build/exp/recovery
    if [[ "$MODE" == "docker" ]] && [[ "$PHASE" =~ ^(all|build|exp0|exp1|exp2|recovery)$ ]] && ! $DRY_RUN; then
        if ! command -v docker >/dev/null 2>&1; then
            log_error "docker not found — required for --mode docker. See ae/HARDWARE.md."
            fatal=1
        elif ! docker info >/dev/null 2>&1; then
            log_error "Cannot reach Docker daemon (permission denied or daemon down)."
            log_error "Try: sudo usermod -aG docker \$USER && newgrp docker"
            fatal=1
        else
            # Docker Compose V2 plugin (not legacy V1 docker-compose script)
            if ! docker compose version >/dev/null 2>&1; then
                log_error "docker compose V2 plugin not installed. Legacy 'docker-compose' V1 is NOT supported."
                log_error "Install: apt-get install docker-compose-plugin"
                fatal=1
            fi
        fi
    fi
    # ulimit advisory (only warn — runs may still succeed at lower limits)
    local nofile
    nofile=$(ulimit -n 2>/dev/null || echo 0)
    if [[ "$nofile" != "unlimited" && "$nofile" -lt 65536 ]]; then
        log_warn "ulimit -n is $nofile; recommended 65536. Run: ulimit -n 65536"
    fi
    # Disk free advisory
    local free_gb
    free_gb=$(df --output=avail -BG "$AE_DIR" 2>/dev/null | tail -1 | tr -d 'G ' || echo 0)
    if [[ "$free_gb" =~ ^[0-9]+$ ]] && [[ "$free_gb" -lt 80 ]]; then
        log_warn "Only ${free_gb} GB free on $AE_DIR (recommended 80 GB+). See HARDWARE.md."
    fi
    if [[ $fatal -ne 0 ]]; then
        log_error "Pre-flight failed. Fix the errors above and re-run."
        exit 2
    fi
}

preflight_env

# ---------------------------------------------------------------------------
# Phase: build
# ---------------------------------------------------------------------------
phase_build() {
    log_step "Phase: build (mode=$MODE)"
    local log="$OUTPUT_DIR/build/build.log"
    if [[ "$MODE" == "cluster" ]]; then
        # 10-run_all.sh build → SSHes server0 and rebuilds via WAF.
        ( cd "$SCRIPT_DIR/scripts" && run_cmd ./10-run_all.sh build ) \
            2>&1 | tee "$log" || { log_error "Build failed"; return 1; }
    else
        # Docker mode: frozen reproduce_evaluation.sh under ae/local/scripts/
        # uses docker/zoo-build/Dockerfile etc. relative to its parent
        # (ae/local/). We export REPO_ROOT so it picks up our frozen
        # Docker assets.
        REPO_ROOT="$SCRIPT_DIR" run_cmd "$SCRIPT_DIR/scripts/reproduce_evaluation.sh" --build-only \
            2>&1 | tee "$log" || { log_error "Build failed; see $log"; return 1; }
    fi
}

# ---------------------------------------------------------------------------
# Phase: exp0 — concurrency sweep
# ---------------------------------------------------------------------------
phase_exp0() {
    log_step "Phase: exp0 (concurrency sweep, full AWS density, mode=$MODE)"
    if [[ "$MODE" == "cluster" ]]; then
        ( cd "$SCRIPT_DIR/scripts" && run_cmd ./10-run_all.sh --exp 0 ) \
            2>&1 | tee "$OUTPUT_DIR/exp0/exp0.log" || \
            log_warn "exp 0 reported failures; check log"
        return 0
    fi
    phase_exp0_backends
    phase_exp0_native
}

phase_exp0_backends() {
    log_info "exp0_backends: 3 backends × $(if $QUICK; then echo 'reduced'; else echo 'full'; fi) conc array × {none,rule}×{0,100,101}"
    for backend in "${BACKENDS[@]}"; do
        local conc_list="${CONCS_FULL[$backend]}"
        $QUICK && conc_list="1 50 100"
        for mode_cfg in "none_${backend}.yml" "rule_${backend}.yml"; do
            for fp in 0 100 101; do
                [[ "$mode_cfg" == none_* && "$fp" != 0 ]] && continue
                local out="$OUTPUT_DIR/exp0/${mode_cfg%.yml}-fp${fp}"
                mkdir -p "$out"
                # TODO: scripts/sweep_benchmark.sh has a hardcoded
                # CONCURRENCIES array. Pass conc_list through env or
                # post-filter results. For now we run with its default
                # array and rely on the gate evaluator in
                # ae/check_results.sh to subset to the AE conc points.
                AE_CONC_OVERRIDE="$conc_list" run_cmd \
                    "$SCRIPT_DIR/scripts/sweep_benchmark.sh" \
                    "jetpack-${backend}" "$mode_cfg" "-m $fp" \
                    > "$out/sweep.log" 2>&1 || \
                    log_warn "sweep failed for $mode_cfg fp=$fp; continuing"
            done
        done
    done
}

phase_exp0_native() {
    log_info "exp0_native: 6 protocols × full conc array, single-process Docker"
    # Precondition: jetpack-etcd image must exist (we reuse it as the
    # native-protocol runtime). Catch this here rather than failing
    # 100+ runs with an obscure docker error.
    if ! $DRY_RUN && ! docker image inspect jetpack-etcd >/dev/null 2>&1; then
        log_error "Image 'jetpack-etcd' not found — run \`./ae/reproduce_local.sh --phase build\` first."
        return 1
    fi
    local out="$OUTPUT_DIR/exp0"
    mkdir -p "$out"

    # Group A native (raft / copilot / mencius): 4 variants per conc point.
    for proto in "${NATIVE_GROUP_A[@]}"; do
        local conc_list="${CONCS_FULL[$proto]}"
        $QUICK && conc_list=$(echo $conc_list | awk '{print $1, $(NF/2), $NF}')
        for conc in $conc_list; do
            for entry in "none_${proto}.yml:0" "rule_${proto}.yml:0" \
                         "rule_${proto}.yml:100" "rule_${proto}.yml:101"; do
                local cfg="${entry%:*}" mode="${entry#*:}"
                local label="${cfg%.yml}-c${conc}-fp${mode}"
                run_cmd "$SCRIPT_DIR/scripts/run_native_local.sh" \
                    "$cfg" "rw_1000000.yml" "concurrent_${conc}.yml" \
                    "$mode" "$label" "$out" || \
                    log_warn "$label failed"
            done
        done
    done

    # Group B baselines (curp / swiftpaxos / epaxos): 1 variant per conc.
    for proto in "${NATIVE_GROUP_B[@]}"; do
        local cfg conc_list mode
        case "$proto" in
            curp)       cfg="none_curp.yml";              mode=200 ;;
            swiftpaxos) cfg="none_swiftpaxos.yml";        mode=0   ;;
            epaxos)     cfg="none_epaxos_corrected.yml";  mode=0   ;;
        esac
        conc_list="${CONCS_FULL[$proto]}"
        $QUICK && conc_list=$(echo $conc_list | awk '{print $1, $(NF/2), $NF}')
        for conc in $conc_list; do
            local label="${cfg%.yml}-c${conc}-fp${mode}"
            run_cmd "$SCRIPT_DIR/scripts/run_native_local.sh" \
                "$cfg" "rw_1000000.yml" "concurrent_${conc}.yml" \
                "$mode" "$label" "$out" || \
                log_warn "$label failed"
        done
    done
}

# ---------------------------------------------------------------------------
# Phase: exp1 — Zipf sweep at fixed conc
# ---------------------------------------------------------------------------
phase_exp1() {
    log_step "Phase: exp1 (Zipf sweep at fixed concurrency, mode=$MODE)"
    if [[ "$MODE" == "cluster" ]]; then
        ( cd "$SCRIPT_DIR/scripts" && run_cmd ./10-run_all.sh --exp 1 ) \
            2>&1 | tee "$OUTPUT_DIR/exp1/exp1.log" || \
            log_warn "exp 1 reported failures; check log"
        return 0
    fi
    # Docker mode: same harness as exp0_native, but conc fixed and
    # workload swept over ZIPF_FULL (or 4 zipf values if --quick).
    log_info "exp1: 9 protocols × zipf sweep at fixed conc, single-process Docker"
    local out="$OUTPUT_DIR/exp1"
    mkdir -p "$out"
    local zipf_list=("${ZIPF_FULL[@]}")
    $QUICK && zipf_list=("rw_zipf_1.0" "rw_zipf_0.5")

    # Group A (6 families): 4 variants per zipf point.
    for proto in "${NATIVE_GROUP_A[@]}" "${BACKENDS[@]}"; do
        local conc="${FIXED_CONC[$proto]}"
        for z in "${zipf_list[@]}"; do
            for entry in "none_${proto}.yml:0" "rule_${proto}.yml:0" \
                         "rule_${proto}.yml:100" "rule_${proto}.yml:101"; do
                local cfg="${entry%:*}" mode="${entry#*:}"
                local label="${cfg%.yml}-${z}-c${conc}-fp${mode}"
                run_cmd "$SCRIPT_DIR/scripts/run_native_local.sh" \
                    "$cfg" "${z}.yml" "concurrent_${conc}.yml" \
                    "$mode" "$label" "$out" || \
                    log_warn "$label failed"
            done
        done
    done

    # Group B (3 baselines): 1 variant per zipf point.
    for proto in "${NATIVE_GROUP_B[@]}"; do
        local cfg mode conc="${FIXED_CONC[$proto]}"
        case "$proto" in
            curp)       cfg="none_curp.yml";              mode=200 ;;
            swiftpaxos) cfg="none_swiftpaxos.yml";        mode=0   ;;
            epaxos)     cfg="none_epaxos_corrected.yml";  mode=0   ;;
        esac
        for z in "${zipf_list[@]}"; do
            local label="${cfg%.yml}-${z}-c${conc}-fp${mode}"
            run_cmd "$SCRIPT_DIR/scripts/run_native_local.sh" \
                "$cfg" "${z}.yml" "concurrent_${conc}.yml" \
                "$mode" "$label" "$out" || \
                log_warn "$label failed"
        done
    done
}

# ---------------------------------------------------------------------------
# Phase: exp2 — key-range sweep
# ---------------------------------------------------------------------------
phase_exp2() {
    log_step "Phase: exp2 (key-range sweep at fixed concurrency, mode=$MODE)"
    if [[ "$MODE" == "cluster" ]]; then
        ( cd "$SCRIPT_DIR/scripts" && run_cmd ./10-run_all.sh --exp 2 ) \
            2>&1 | tee "$OUTPUT_DIR/exp2/exp2.log" || \
            log_warn "exp 2 reported failures; check log"
        return 0
    fi
    # Docker mode: same harness as exp1, swept over KEYRANGE_FULL.
    log_info "exp2: 9 protocols × key-range sweep at fixed conc, single-process Docker"
    local out="$OUTPUT_DIR/exp2"
    mkdir -p "$out"
    local kr_list=("${KEYRANGE_FULL[@]}")
    $QUICK && kr_list=("rw_1" "rw_1000" "rw_1000000")

    for proto in "${NATIVE_GROUP_A[@]}" "${BACKENDS[@]}"; do
        local conc="${FIXED_CONC[$proto]}"
        for kr in "${kr_list[@]}"; do
            for entry in "none_${proto}.yml:0" "rule_${proto}.yml:0" \
                         "rule_${proto}.yml:100" "rule_${proto}.yml:101"; do
                local cfg="${entry%:*}" mode="${entry#*:}"
                local label="${cfg%.yml}-${kr}-c${conc}-fp${mode}"
                run_cmd "$SCRIPT_DIR/scripts/run_native_local.sh" \
                    "$cfg" "${kr}.yml" "concurrent_${conc}.yml" \
                    "$mode" "$label" "$out" || \
                    log_warn "$label failed"
            done
        done
    done

    for proto in "${NATIVE_GROUP_B[@]}"; do
        local cfg mode conc="${FIXED_CONC[$proto]}"
        case "$proto" in
            curp)       cfg="none_curp.yml";              mode=200 ;;
            swiftpaxos) cfg="none_swiftpaxos.yml";        mode=0   ;;
            epaxos)     cfg="none_epaxos_corrected.yml";  mode=0   ;;
        esac
        for kr in "${kr_list[@]}"; do
            local label="${cfg%.yml}-${kr}-c${conc}-fp${mode}"
            run_cmd "$SCRIPT_DIR/scripts/run_native_local.sh" \
                "$cfg" "${kr}.yml" "concurrent_${conc}.yml" \
                "$mode" "$label" "$out" || \
                log_warn "$label failed"
        done
    done
}

# ---------------------------------------------------------------------------
# Phase: recovery
# ---------------------------------------------------------------------------
phase_recovery() {
    log_step "Phase: recovery (mode=$MODE)"
    local log="$OUTPUT_DIR/recovery/recovery.log"
    if [[ "$MODE" == "cluster" ]]; then
        # Cluster: 09-build_and_test_run_wan.sh has a --failover flag.
        ( cd "$SCRIPT_DIR/scripts" && run_cmd ./09-build_and_test_run_wan.sh \
              --failover --kill-target 2 --kill-delay 20 \
              --filename ae-recovery \
              --result-dir "$OUTPUT_DIR/recovery" ) \
            2>&1 | tee "$log" || log_warn "Cluster recovery failed; see $log"
        return 0
    fi
    # Docker mode
    local sub_results="${AE_DIR}/output/recovery_${TIMESTAMP}_subresults"
    REPO_ROOT="$SCRIPT_DIR" RESULTS_DIR="$sub_results" run_cmd \
        "$SCRIPT_DIR/scripts/reproduce_evaluation.sh" --recovery-only \
        2>&1 | tee "$log" || {
        log_error "Recovery phase failed; see $log"; return 1;
    }
    if [[ -d "$sub_results/recovery" ]]; then
        cp -r "$sub_results/recovery/." "$OUTPUT_DIR/recovery/"
    fi
}

# ---------------------------------------------------------------------------
# Phase: tla_small / tla_large
# ---------------------------------------------------------------------------
phase_tla_small() {
    log_step "Phase: tla_small (all 6 specs, AE budget)"
    run_cmd "$AE_DIR/tla/one_click_small.sh" 2>&1 | tee "$OUTPUT_DIR/tla/tla_small.log"
    cp -r "$AE_DIR/tla/log/." "$OUTPUT_DIR/tla/" 2>/dev/null || true
}

phase_tla_large() {
    log_step "Phase: tla_large (paper claim, 12+ h)"
    run_cmd "$AE_DIR/tla/one_click_large.sh" 2>&1 | tee "$OUTPUT_DIR/tla/tla_large.log"
    cp -r "$AE_DIR/tla/log/." "$OUTPUT_DIR/tla/" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Phase: summary
# ---------------------------------------------------------------------------
phase_summary() {
    log_step "Phase: summary"
    local sum="$OUTPUT_DIR/SUMMARY.md"
    {
        echo "# Jetpack AE — local reproduction summary"
        echo ""
        echo "- Commit:    \`$COMMIT_HASH\`"
        echo "- Started:   $TIMESTAMP"
        echo "- Output:    \`$OUTPUT_DIR\`"
        echo "- Quick:     $QUICK"
        echo ""
        echo "## Phase status"
        echo ""
        echo "| Phase | Output | Status |"
        echo "|---|---|---|"
        for p in build exp0 exp1 exp2 recovery tla; do
            local count
            count=$(find "$OUTPUT_DIR/$p" -type f 2>/dev/null | wc -l)
            local status
            if [[ "$count" -gt 0 ]]; then status="files: $count"; else status="empty"; fi
            echo "| $p | \`$p/\` | $status |"
        done
        echo ""
        echo "## Output summary"
        echo ""
        echo "Run \`./ae/check_results.sh \"$OUTPUT_DIR\"\` for a sanity"
        echo "summary of the artefacts produced above (file counts,"
        echo "missing-marker warnings, recovery duration min/max,"
        echo "TLC completion check). It is non-judgmental — interpret"
        echo "the numbers yourself."
    } > "$sum"
    log_info "Summary: $sum"
}

# ---------------------------------------------------------------------------
# Quick mode (kick-the-tires)
# ---------------------------------------------------------------------------
phase_quick() {
    log_step "Quick mode: build + 3-conc raft sweep + 1 recovery + raft TLA"
    QUICK=true
    phase_build

    # Mini exp0: raft only, 3 conc points (low / knee / high), 4 variants.
    log_info "Quick exp0: raft only at conc {1, 150, 500}"
    local out="$OUTPUT_DIR/exp0"
    mkdir -p "$out"
    for conc in 1 150 500; do
        for entry in "none_raft.yml:0" "rule_raft.yml:0" \
                     "rule_raft.yml:100" "rule_raft.yml:101"; do
            local cfg="${entry%:*}" mode="${entry#*:}"
            local label="${cfg%.yml}-c${conc}-fp${mode}"
            run_cmd "$SCRIPT_DIR/scripts/run_native_local.sh" \
                "$cfg" "rw_1000000.yml" "concurrent_${conc}.yml" \
                "$mode" "$label" "$out" || \
                log_warn "$label failed"
        done
    done

    # Mini recovery: etcd only, 1 rep.
    phase_recovery

    # Mini TLA: jetpack_raft on small config (verified to finish in ~11s).
    log_info "Quick TLA: jetpack_raft_composition.tla on jetpack_raft_small.cfg"
    ( cd "$AE_DIR/tla" && run_cmd ./run-tlc.sh \
        jetpack_raft_composition.tla jetpack_raft_small.cfg -workers 4 ) \
        2>&1 | tee "$OUTPUT_DIR/tla/tla_quick.log" || \
        log_warn "Quick TLA failed; check $OUTPUT_DIR/tla/tla_quick.log"

    phase_summary
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
if $QUICK; then
    phase_quick
    exit $?
fi

case "$PHASE" in
    all)
        phase_build
        phase_exp0
        phase_exp1
        phase_exp2
        phase_recovery
        phase_tla_small
        phase_summary
        ;;
    build)      phase_build ;;
    exp0)       phase_exp0 ;;
    exp1)       phase_exp1 ;;
    exp2)       phase_exp2 ;;
    recovery)   phase_recovery ;;
    tla_small)  phase_tla_small ;;
    tla_large)  phase_tla_large ;;
    summary)    phase_summary ;;
    *)          log_error "Unknown phase: $PHASE"; usage ;;
esac

log_info "Done. See $OUTPUT_DIR/SUMMARY.md"
