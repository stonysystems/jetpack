#!/usr/bin/env bash
# reproduce_evaluation.sh — End-to-end evaluation reproduction script.
#
# Builds fresh Docker images from the current checkout, runs the full
# benchmark and recovery matrices, and regenerates result artifacts.
# Designed to be run by a fresh Codex agent or developer following
# docs/benchmark_runbook.md.
#
# Usage:
#   ./scripts/reproduce_evaluation.sh                # Full end-to-end
#   ./scripts/reproduce_evaluation.sh --build-only   # Only build images
#   ./scripts/reproduce_evaluation.sh --sanity-only  # Build + 6 sanity runs
#   ./scripts/reproduce_evaluation.sh --sweep-only   # Build + 9-case sweep
#   ./scripts/reproduce_evaluation.sh --recovery-only # Build + 3 recovery tests
#   ./scripts/reproduce_evaluation.sh --dry-run      # Print all commands without executing
#   ./scripts/reproduce_evaluation.sh --help
#
# Prerequisites:
#   - Docker Engine >= 17.05 with Docker Compose V2
#   - Git submodules initialized: git submodule update --init --recursive
#   - Privileged mode capability (for tc/netem)
#
# Output:
#   - Build logs:    results/reproduce_<timestamp>/build/
#   - Sanity logs:   results/reproduce_<timestamp>/sanity/
#   - Sweep results: results/reproduce_<timestamp>/sweep/
#   - Recovery logs: results/reproduce_<timestamp>/recovery/
#   - Summary:       results/reproduce_<timestamp>/SUMMARY.md

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
COMMIT_HASH="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
RESULTS_DIR="${RESULTS_DIR:-${REPO_ROOT}/results/reproduce_${TIMESTAMP}}"

BACKENDS=(etcd mongodb zookeeper)
MODES_ORIGINAL=(none_etcd.yml none_mongodb.yml none_zookeeper.yml)
MODES_FASTPATH=(rule_etcd.yml rule_mongodb.yml rule_zookeeper.yml)
# Adaptive uses the same rule config with default -m 101 (no extra args needed)

SANITY_REPEATS=3
RECOVERY_REPEATS=3
RECOVERY_LATENCY_MS=20

DRY_RUN=false
BUILD_ONLY=false
SANITY_ONLY=false
SWEEP_ONLY=false
RECOVERY_ONLY=false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log_info()  { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
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
# Parse arguments
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n)      DRY_RUN=true ;;
        --build-only)      BUILD_ONLY=true ;;
        --sanity-only)     SANITY_ONLY=true ;;
        --sweep-only)      SWEEP_ONLY=true ;;
        --recovery-only)   RECOVERY_ONLY=true ;;
        --help|-h)         usage ;;
        *)                 log_error "Unknown argument: $arg"; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight() {
    log_step "Preflight Checks"

    # Docker
    if ! command -v docker &>/dev/null; then
        log_error "Docker not found. Install Docker Engine >= 17.05."
        exit 1
    fi
    log_info "Docker: $(docker --version)"

    # Docker Compose V2
    if ! docker compose version &>/dev/null; then
        log_error "Docker Compose V2 not found. Install 'docker compose' plugin."
        exit 1
    fi
    log_info "Compose: $(docker compose version)"

    # Git submodules
    local missing=false
    for f in third_party/mongo-c-driver/CMakeLists.txt \
             third_party/mongo-cxx-driver/CMakeLists.txt \
             third_party/etcd-cpp-apiv3/CMakeLists.txt \
             third_party/zookeeper/zookeeper-client/zookeeper-client-c/CMakeLists.txt; do
        if [ ! -f "$REPO_ROOT/$f" ]; then
            log_error "Missing: $f"
            missing=true
        fi
    done
    if $missing; then
        log_error "Initialize submodules: git submodule update --init --recursive"
        exit 1
    fi
    log_info "Git submodules: OK"

    # Output directory
    mkdir -p "$RESULTS_DIR"
    log_info "Results directory: $RESULTS_DIR"
    log_info "Commit: $COMMIT_HASH"
    log_info "Timestamp: $TIMESTAMP"
}

# ---------------------------------------------------------------------------
# Phase 1: Build fresh images
# ---------------------------------------------------------------------------
build_images() {
    log_step "Phase 1: Build Fresh Docker Images"

    mkdir -p "$RESULTS_DIR/build"
    local metadata_file="$RESULTS_DIR/build/image_metadata.tsv"

    # Remove old images to ensure clean-room build
    for backend in "${BACKENDS[@]}"; do
        local image="jetpack-${backend}"
        if docker image inspect "$image" &>/dev/null; then
            log_info "Removing existing image: $image"
            run_cmd docker rmi "$image" 2>/dev/null || true
        fi
    done

    if $DRY_RUN; then
        echo "  [DRY-RUN] write build metadata to $metadata_file"
    else
        printf "backend\timage_tag\timage_id\tcreated_at\tcommit\tbuilt_at\n" > "$metadata_file"
    fi

    # Build each backend
    for backend in "${BACKENDS[@]}"; do
        local compose_file="docker/${backend}/docker-compose.yml"
        local image="jetpack-${backend}"
        local log_file="$RESULTS_DIR/build/${backend}.log"
        log_info "Building $image ..."
        if $DRY_RUN; then
            echo "  [DRY-RUN] docker compose -f $compose_file build 2>&1 | tee $log_file"
        else
            local start_time
            start_time=$(date +%s)
            if docker compose -f "$REPO_ROOT/$compose_file" build 2>&1 | tee "$log_file"; then
                local end_time
                end_time=$(date +%s)
                log_info "Built $image in $((end_time - start_time))s"

                local image_id
                local created_at
                local built_at
                image_id="$(docker image inspect --format '{{.Id}}' "$image")"
                created_at="$(docker image inspect --format '{{.Created}}' "$image")"
                built_at="$(date -Iseconds)"
                printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
                    "$backend" "$image" "$image_id" "$created_at" "$COMMIT_HASH" "$built_at" \
                    >> "$metadata_file"
                log_info "Image metadata: $image id=${image_id#sha256:}"
            else
                log_error "Failed to build $image. See $log_file"
                return 1
            fi
        fi
    done

    # Verify images exist
    for backend in "${BACKENDS[@]}"; do
        if ! $DRY_RUN; then
            if docker image inspect "jetpack-${backend}" &>/dev/null; then
                log_info "Verified: jetpack-${backend} exists"
            else
                log_error "Image jetpack-${backend} not found after build"
                return 1
            fi
        fi
    done

    if ! $DRY_RUN; then
        log_info "Build metadata: $metadata_file"
    fi
    log_info "All 3 backend images built successfully."
}

# ---------------------------------------------------------------------------
# Phase 2: Sanity runs (6 cases, 3 repeats each)
# ---------------------------------------------------------------------------
sanity_runs() {
    log_step "Phase 2: Low-Concurrency Sanity Runs (6 cases × ${SANITY_REPEATS} repeats)"

    mkdir -p "$RESULTS_DIR/sanity"
    local pass=0
    local fail=0

    for backend_idx in 0 1 2; do
        local backend="${BACKENDS[$backend_idx]}"
        local mode_off="${MODES_ORIGINAL[$backend_idx]}"
        local mode_on="${MODES_FASTPATH[$backend_idx]}"

        for mode_name in "off" "on"; do
            local mode_config
            if [ "$mode_name" = "off" ]; then
                mode_config="$mode_off"
            else
                mode_config="$mode_on"
            fi

            for repeat in $(seq 1 "$SANITY_REPEATS"); do
                local label="${backend}_jetpack-${mode_name}_r${repeat}"
                local log_file="$RESULTS_DIR/sanity/${label}.log"
                log_info "Running: ${backend} Jetpack=${mode_name} (repeat ${repeat}/${SANITY_REPEATS})"

                if $DRY_RUN; then
                    echo "  [DRY-RUN] docker run --rm --privileged" \
                         "-e MODE_CONFIG=${mode_config}" \
                         "-e CONCURRENT_CONFIG=concurrent_1.yml" \
                         "-e TEST_DURATION=10" \
                         "jetpack-${backend} benchmark"
                else
                    if docker run --rm --privileged \
                        -e MODE_CONFIG="$mode_config" \
                        -e CONCURRENT_CONFIG=concurrent_1.yml \
                        -e TEST_DURATION=10 \
                        "jetpack-${backend}" benchmark \
                        > "$log_file" 2>&1; then
                        log_info "  PASS: $label"
                        pass=$((pass + 1))
                    else
                        log_error "  FAIL: $label (exit $?)"
                        fail=$((fail + 1))
                    fi
                fi
            done
        done
    done

    log_info "Sanity results: ${pass} passed, ${fail} failed (total $((pass + fail)))"
    if [ "$fail" -gt 0 ]; then
        log_error "Some sanity runs failed. Check logs in $RESULTS_DIR/sanity/"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Phase 3: Full 9-case throughput sweep
# ---------------------------------------------------------------------------
throughput_sweep() {
    log_step "Phase 3: Full 9-Case Throughput Sweep"

    mkdir -p "$RESULTS_DIR/sweep"
    local pass=0
    local fail=0

    for backend_idx in 0 1 2; do
        local backend="${BACKENDS[$backend_idx]}"
        local image="jetpack-${backend}"
        local mode_off="${MODES_ORIGINAL[$backend_idx]}"
        local mode_fp="${MODES_FASTPATH[$backend_idx]}"

        # 1. Original (no Jetpack)
        local out_original="$RESULTS_DIR/sweep/${backend}_original.tsv"
        log_info "Sweep: ${backend} original"
        if $DRY_RUN; then
            echo "  [DRY-RUN] ./scripts/sweep_benchmark.sh $image $mode_off > $out_original"
        else
            if "$REPO_ROOT/scripts/sweep_benchmark.sh" "$image" "$mode_off" \
                > "$out_original" 2>"$RESULTS_DIR/sweep/${backend}_original.stderr"; then
                log_info "  PASS: ${backend} original"
                pass=$((pass + 1))
            else
                log_error "  FAIL: ${backend} original"
                fail=$((fail + 1))
            fi
        fi

        # 2. Fastpath 100%
        local out_fp="$RESULTS_DIR/sweep/${backend}_fastpath100.tsv"
        log_info "Sweep: ${backend} fastpath100"
        if $DRY_RUN; then
            echo "  [DRY-RUN] ./scripts/sweep_benchmark.sh $image $mode_fp '-m 100' > $out_fp"
        else
            if "$REPO_ROOT/scripts/sweep_benchmark.sh" "$image" "$mode_fp" "-m 100" \
                > "$out_fp" 2>"$RESULTS_DIR/sweep/${backend}_fastpath100.stderr"; then
                log_info "  PASS: ${backend} fastpath100"
                pass=$((pass + 1))
            else
                log_error "  FAIL: ${backend} fastpath100"
                fail=$((fail + 1))
            fi
        fi

        # 3. Adaptive (default -m 101)
        local out_adaptive="$RESULTS_DIR/sweep/${backend}_adaptive.tsv"
        log_info "Sweep: ${backend} adaptive"
        if $DRY_RUN; then
            echo "  [DRY-RUN] ./scripts/sweep_benchmark.sh $image $mode_fp > $out_adaptive"
        else
            if "$REPO_ROOT/scripts/sweep_benchmark.sh" "$image" "$mode_fp" \
                > "$out_adaptive" 2>"$RESULTS_DIR/sweep/${backend}_adaptive.stderr"; then
                log_info "  PASS: ${backend} adaptive"
                pass=$((pass + 1))
            else
                log_error "  FAIL: ${backend} adaptive"
                fail=$((fail + 1))
            fi
        fi
    done

    log_info "Sweep results: ${pass} passed, ${fail} failed (total $((pass + fail)))"

    # Generate consolidated CSV and Markdown
    if ! $DRY_RUN && [ "$fail" -eq 0 ]; then
        log_info "Generating consolidated results..."
        if [ -x "$REPO_ROOT/scripts/build_consolidated_csv.sh" ]; then
            "$REPO_ROOT/scripts/build_consolidated_csv.sh" "$RESULTS_DIR/sweep" \
                > "$RESULTS_DIR/sweep/consolidated.csv" 2>/dev/null || true
        fi
        if [ -x "$REPO_ROOT/scripts/tsv_to_md.sh" ]; then
            for tsv in "$RESULTS_DIR/sweep/"*.tsv; do
                local md="${tsv%.tsv}.md"
                "$REPO_ROOT/scripts/tsv_to_md.sh" < "$tsv" > "$md" 2>/dev/null || true
            done
        fi
    fi

    if [ "$fail" -gt 0 ]; then
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Phase 4: WAN recovery tests (3 backends, N repeats each)
# ---------------------------------------------------------------------------
recovery_tests() {
    log_step "Phase 4: WAN Recovery Tests (3 backends × ${RECOVERY_REPEATS} repeats, ${RECOVERY_LATENCY_MS}ms latency)"

    mkdir -p "$RESULTS_DIR/recovery"
    local pass=0
    local fail=0

    for backend in "${BACKENDS[@]}"; do
        local compose_file="docker/${backend}/docker-compose.yml"

        for repeat in $(seq 1 "$RECOVERY_REPEATS"); do
            local label="${backend}_wan_r${repeat}"
            local log_file="$RESULTS_DIR/recovery/${label}.log"
            log_info "Recovery: ${backend} (repeat ${repeat}/${RECOVERY_REPEATS})"

            if $DRY_RUN; then
                echo "  [DRY-RUN] docker compose -f $compose_file run --rm" \
                     "-e RECOVERY_LATENCY_MS=${RECOVERY_LATENCY_MS}" \
                     "jetpack-${backend} recovery"
            else
                if docker compose -f "$REPO_ROOT/$compose_file" run --rm \
                    -e RECOVERY_LATENCY_MS="$RECOVERY_LATENCY_MS" \
                    "jetpack-${backend}" recovery \
                    > "$log_file" 2>&1; then
                    log_info "  PASS: $label"
                    pass=$((pass + 1))
                else
                    log_error "  FAIL: $label (exit $?)"
                    fail=$((fail + 1))
                fi
            fi
        done
    done

    log_info "Recovery results: ${pass} passed, ${fail} failed (total $((pass + fail)))"
    if [ "$fail" -gt 0 ]; then
        log_error "Some recovery tests failed. Check logs in $RESULTS_DIR/recovery/"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
generate_summary() {
    log_step "Generating Summary"

    local summary="$RESULTS_DIR/SUMMARY.md"
    cat > "$summary" <<EOF
# Evaluation Reproduction Summary

- **Date**: $(date -Iseconds)
- **Commit**: $COMMIT_HASH
- **Results**: $RESULTS_DIR

## Phases Completed

| Phase | Description | Status |
|-------|-------------|--------|
EOF

    if [ -d "$RESULTS_DIR/build" ]; then
        local build_status="PASS"
        for backend in "${BACKENDS[@]}"; do
            if [ ! -f "$RESULTS_DIR/build/${backend}.log" ]; then
                build_status="SKIP"
            fi
        done
        echo "| 1 | Build fresh images | $build_status |" >> "$summary"
    fi

    if [ -d "$RESULTS_DIR/sanity" ]; then
        local sanity_pass sanity_total
        sanity_pass=$(grep -rl "Mid throughput" "$RESULTS_DIR/sanity/" 2>/dev/null | wc -l || echo 0)
        sanity_total=$(ls "$RESULTS_DIR/sanity/"*.log 2>/dev/null | wc -l || echo 0)
        echo "| 2 | Sanity runs | ${sanity_pass}/${sanity_total} |" >> "$summary"
    fi

    if [ -d "$RESULTS_DIR/sweep" ]; then
        local sweep_count
        sweep_count=$(ls "$RESULTS_DIR/sweep/"*.tsv 2>/dev/null | wc -l || echo 0)
        echo "| 3 | Throughput sweep | ${sweep_count}/9 cases |" >> "$summary"
    fi

    if [ -d "$RESULTS_DIR/recovery" ]; then
        local recovery_pass recovery_total
        recovery_pass=$(grep -rl "Recovery\|recovery" "$RESULTS_DIR/recovery/" 2>/dev/null | wc -l || echo 0)
        recovery_total=$(ls "$RESULTS_DIR/recovery/"*.log 2>/dev/null | wc -l || echo 0)
        echo "| 4 | WAN recovery | ${recovery_pass}/${recovery_total} |" >> "$summary"
    fi

    cat >> "$summary" <<EOF

## Acceptance Checklist

- [ ] Fresh images built from current repo (no pre-existing images)
- [ ] Runbook commands pass as documented
- [ ] 6 low-concurrency sanity runs reproduced (3 repeats each)
- [ ] 9-case throughput sweep completed from fresh images
- [ ] 3-backend WAN recovery completed (${RECOVERY_LATENCY_MS}ms latency)
- [ ] Canonical artifacts regenerated and consistent
- [ ] No unresolved contradictions in published docs
EOF

    local metadata_file="$RESULTS_DIR/build/image_metadata.tsv"
    if [ -f "$metadata_file" ]; then
        cat >> "$summary" <<EOF

## Build Metadata

| Backend | Image Tag | Image ID | Created At | Commit | Built At |
|---|---|---|---|---|---|
EOF
        awk -F'\t' 'NR > 1 {
            image_id = $3
            sub(/^sha256:/, "", image_id)
            printf("| %s | `%s` | `%s` | %s | `%s` | %s |\n", $1, $2, image_id, $4, $5, $6)
        }' "$metadata_file" >> "$summary"
    fi

    if ! $DRY_RUN; then
        log_info "Summary written to: $summary"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    cd "$REPO_ROOT"

    preflight

    # Determine which phases to run
    local do_build=true
    local do_sanity=true
    local do_sweep=true
    local do_recovery=true

    if $BUILD_ONLY; then
        do_sanity=false; do_sweep=false; do_recovery=false
    elif $SANITY_ONLY; then
        do_sweep=false; do_recovery=false
    elif $SWEEP_ONLY; then
        do_sanity=false; do_recovery=false
    elif $RECOVERY_ONLY; then
        do_sanity=false; do_sweep=false
    fi

    # Execute phases
    local exit_code=0

    if $do_build; then
        build_images || exit_code=1
    fi

    if [ "$exit_code" -eq 0 ] && $do_sanity; then
        sanity_runs || exit_code=1
    fi

    if [ "$exit_code" -eq 0 ] && $do_sweep; then
        throughput_sweep || exit_code=1
    fi

    if [ "$exit_code" -eq 0 ] && $do_recovery; then
        recovery_tests || exit_code=1
    fi

    generate_summary

    if [ "$exit_code" -eq 0 ]; then
        log_step "ALL PHASES PASSED"
    else
        log_step "SOME PHASES FAILED — check logs in $RESULTS_DIR"
    fi

    return "$exit_code"
}

main "$@"
