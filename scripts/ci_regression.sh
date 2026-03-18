#!/bin/bash
# ci_regression.sh — Checked-in CI entrypoint for Jetpack regression smoke tests.
#
# Runs the 12-mode regression matrix across two lanes:
#   1. 3c1s3r1p + SIMULATE_WAN  (software-sleep latency, single process)
#   2. 5c1s5r5p + tc/netem      (kernel-level latency, multi process)
#
# This is a REGRESSION SMOKE GATE — it uses short durations and low
# concurrency. It does NOT reproduce published benchmark numbers.
#
# Usage:
#   ./scripts/ci_regression.sh                  # run both lanes
#   ./scripts/ci_regression.sh --lane wan       # SIMULATE_WAN lane only
#   ./scripts/ci_regression.sh --lane tc        # tc/netem lane only
#   ./scripts/ci_regression.sh --dry-run        # print matrix, don't execute
#
# Environment:
#   SMOKE_DURATION   - test duration per mode in seconds (default: 5)
#   SMOKE_CONCURRENT - concurrent requests per client (default: 1)
#   CI_LOG_DIR       - log output directory (default: ci_logs/<timestamp>)
#
# Runner prerequisites:
#   SIMULATE_WAN lane: Jetpack binary built with SIMULATE_WAN enabled
#     (python3 waf configure build -W, or uncomment in constants.h and rebuild)
#   tc lane: Docker with --privileged, iproute2 installed, tc/netem support
#
# Exit codes:
#   0 = all modes passed (or skipped with documented reason)
#   1 = at least one mode failed (build failure, crash, empty output)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Configuration ──────────────────────────────────────────────────────

SMOKE_DURATION="${SMOKE_DURATION:-5}"
SMOKE_CONCURRENT="${SMOKE_CONCURRENT:-1}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
CI_LOG_DIR="${CI_LOG_DIR:-${REPO_DIR}/ci_logs/${TIMESTAMP}}"

# The 12 mode configs required by the regression matrix.
# Format: <cc>_<ab> where cc is none|rule and ab is the protocol.
MODES=(
    none_raft
    none_copilot
    none_mencius
    none_mongodb
    none_zookeeper
    none_etcd
    rule_raft
    rule_copilot
    rule_mencius
    rule_mongodb
    rule_zookeeper
    rule_etcd
)

# Protocols that are built into Jetpack (no external backend needed).
BUILTIN_PROTOCOLS=(raft copilot mencius)

# Protocols that require an external backend (Docker).
BACKEND_PROTOCOLS=(mongodb zookeeper etcd)

# ── Helpers ────────────────────────────────────────────────────────────

log_info()  { echo "[CI $(date +%H:%M:%S)] INFO  $*"; }
log_warn()  { echo "[CI $(date +%H:%M:%S)] WARN  $*" >&2; }
log_error() { echo "[CI $(date +%H:%M:%S)] ERROR $*" >&2; }

is_builtin() {
    local ab="$1"
    for b in "${BUILTIN_PROTOCOLS[@]}"; do
        [[ "$ab" == "$b" ]] && return 0
    done
    return 1
}

extract_ab() {
    # Extract atomic broadcast name from mode config (e.g., "none_raft" -> "raft")
    echo "${1#*_}"
}

extract_cc() {
    # Extract concurrency control from mode config (e.g., "none_raft" -> "none")
    echo "${1%%_*}"
}

# ── Lane: SIMULATE_WAN (3c1s3r1p, single process) ─────────────────────

run_wan_lane() {
    local site_config="3c1s3r1p"
    local lane_dir="${CI_LOG_DIR}/wan_lane"
    mkdir -p "$lane_dir"

    log_info "=== SIMULATE_WAN lane: ${site_config} ==="
    log_info "Duration: ${SMOKE_DURATION}s, Concurrent: ${SMOKE_CONCURRENT}"
    log_info "Log dir: ${lane_dir}"

    local pass=0 fail=0 skip=0

    for mode in "${MODES[@]}"; do
        local ab
        ab=$(extract_ab "$mode")
        local cc
        cc=$(extract_cc "$mode")
        local log_file="${lane_dir}/${mode}.log"
        local status="SKIP"

        log_info "  [${mode}] starting..."

        # Check if binary exists
        if [[ ! -x "${REPO_DIR}/build/deptran_server" ]]; then
            log_warn "  [${mode}] SKIP — build/deptran_server not found"
            echo "status=SKIP reason=binary_not_found" > "${log_file}.status"
            skip=$((skip + 1))
            continue
        fi

        # Backend protocols need Docker — skip in WAN lane
        if ! is_builtin "$ab"; then
            log_warn "  [${mode}] SKIP — backend protocol '${ab}' requires Docker"
            echo "status=SKIP reason=backend_requires_docker" > "${log_file}.status"
            skip=$((skip + 1))
            continue
        fi

        # Determine fastpath mode flag
        local mode_flag="0"
        if [[ "$cc" == "rule" ]]; then
            mode_flag="101"  # adaptive
        fi

        # Run smoke test
        local cmd="${REPO_DIR}/build/deptran_server"
        cmd+=" -f config/${mode}.yml"
        cmd+=" -f config/client_open.yml"
        cmd+=" -f config/${site_config}.yml"
        cmd+=" -f config/rw_1000000.yml"
        cmd+=" -f config/concurrent_${SMOKE_CONCURRENT}.yml"
        cmd+=" -m ${mode_flag}"
        cmd+=" -d ${SMOKE_DURATION}"

        log_info "  [${mode}] cmd: ${cmd}"

        if timeout $((SMOKE_DURATION + 30)) bash -c "cd '${REPO_DIR}' && ${cmd}" \
            > "$log_file" 2>&1; then
            # Check for non-empty output with throughput
            if grep -q "txn.*committed\|throughput\|total.*cmd" "$log_file" 2>/dev/null; then
                status="PASS"
                pass=$((pass + 1))
            else
                status="FAIL"
                fail=$((fail + 1))
                log_error "  [${mode}] FAIL — no throughput in output"
            fi
        else
            status="FAIL"
            fail=$((fail + 1))
            log_error "  [${mode}] FAIL — process crashed or timed out"
        fi

        echo "status=${status}" > "${log_file}.status"
        log_info "  [${mode}] ${status}"
    done

    log_info "=== SIMULATE_WAN lane results: pass=${pass} fail=${fail} skip=${skip} ==="
    return $((fail > 0 ? 1 : 0))
}

# ── Lane: tc/netem (5c1s5r5p, multi process) ──────────────────────────

run_tc_lane() {
    local site_config="5c1s5r5p_local"
    local lane_dir="${CI_LOG_DIR}/tc_lane"
    mkdir -p "$lane_dir"

    log_info "=== tc/netem lane: ${site_config} ==="
    log_info "Duration: ${SMOKE_DURATION}s, Concurrent: ${SMOKE_CONCURRENT}"
    log_info "Log dir: ${lane_dir}"

    # Check prerequisites
    if ! command -v tc &>/dev/null; then
        log_warn "tc command not found — tc lane BLOCKED"
        echo "status=BLOCKED reason=tc_not_available" > "${lane_dir}/lane.status"
        return 0  # Not a failure — blocked is documented
    fi

    if ! tc qdisc show dev lo &>/dev/null 2>&1; then
        log_warn "tc requires privileges — tc lane BLOCKED"
        echo "status=BLOCKED reason=privileges_required" > "${lane_dir}/lane.status"
        return 0
    fi

    local pass=0 fail=0 skip=0

    for mode in "${MODES[@]}"; do
        local ab
        ab=$(extract_ab "$mode")
        local cc
        cc=$(extract_cc "$mode")
        local log_file="${lane_dir}/${mode}.log"
        local status="SKIP"

        log_info "  [${mode}] starting..."

        # Backend protocols need Docker
        if ! is_builtin "$ab"; then
            # Check if Docker image exists for this backend
            local docker_image="jetpack-${ab}"
            if ! docker image inspect "$docker_image" &>/dev/null 2>&1; then
                log_warn "  [${mode}] SKIP — Docker image '${docker_image}' not found"
                echo "status=SKIP reason=docker_image_missing" > "${log_file}.status"
                skip=$((skip + 1))
                continue
            fi

            # Run via Docker test script
            local test_script="${REPO_DIR}/docker/${ab}/run-${ab}-test.sh"
            if [[ ! -x "$test_script" ]]; then
                log_warn "  [${mode}] SKIP — test script not found"
                echo "status=SKIP reason=test_script_missing" > "${log_file}.status"
                skip=$((skip + 1))
                continue
            fi

            local mode_config="${mode}.yml"
            if timeout $((SMOKE_DURATION + 60)) docker run --rm --privileged \
                -e SITE_CONFIG="${site_config}.yml" \
                -e MODE_CONFIG="${mode_config}" \
                -e CLIENT_CONFIG="client_open.yml" \
                -e CONCURRENT_CONFIG="concurrent_${SMOKE_CONCURRENT}.yml" \
                -e LATENCY_MS=20 \
                -e TEST_DURATION="${SMOKE_DURATION}" \
                "$docker_image" benchmark \
                > "$log_file" 2>&1; then
                status="PASS"
                pass=$((pass + 1))
            else
                status="FAIL"
                fail=$((fail + 1))
                log_error "  [${mode}] FAIL — Docker benchmark failed"
            fi
        else
            # Built-in protocol — run directly with tc/netem
            if [[ ! -x "${REPO_DIR}/build/deptran_server" ]]; then
                log_warn "  [${mode}] SKIP — binary not found"
                echo "status=SKIP reason=binary_not_found" > "${log_file}.status"
                skip=$((skip + 1))
                continue
            fi

            local mode_flag="0"
            if [[ "$cc" == "rule" ]]; then
                mode_flag="101"
            fi

            local cmd="${REPO_DIR}/build/deptran_server"
            cmd+=" -f config/${mode}.yml"
            cmd+=" -f config/client_open.yml"
            cmd+=" -f config/${site_config}.yml"
            cmd+=" -f config/rw_1000000.yml"
            cmd+=" -f config/concurrent_${SMOKE_CONCURRENT}.yml"
            cmd+=" -m ${mode_flag}"
            cmd+=" -d ${SMOKE_DURATION}"

            if timeout $((SMOKE_DURATION + 30)) bash -c "cd '${REPO_DIR}' && ${cmd}" \
                > "$log_file" 2>&1; then
                if grep -q "txn.*committed\|throughput\|total.*cmd" "$log_file" 2>/dev/null; then
                    status="PASS"
                    pass=$((pass + 1))
                else
                    status="FAIL"
                    fail=$((fail + 1))
                    log_error "  [${mode}] FAIL — no throughput in output"
                fi
            else
                status="FAIL"
                fail=$((fail + 1))
                log_error "  [${mode}] FAIL — process crashed or timed out"
            fi
        fi

        echo "status=${status}" > "${log_file}.status"
        log_info "  [${mode}] ${status}"
    done

    log_info "=== tc/netem lane results: pass=${pass} fail=${fail} skip=${skip} ==="
    return $((fail > 0 ? 1 : 0))
}

# ── Summary report ─────────────────────────────────────────────────────

generate_summary() {
    local summary_file="${CI_LOG_DIR}/summary.txt"
    {
        echo "Jetpack CI Regression Smoke Gate"
        echo "================================"
        echo "Timestamp: ${TIMESTAMP}"
        echo "Commit:    $(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
        echo "Duration:  ${SMOKE_DURATION}s per mode"
        echo "Concurrent: ${SMOKE_CONCURRENT}"
        echo ""
        echo "This is a REGRESSION SMOKE GATE, not a benchmark reproduction."
        echo ""

        for lane_dir in "${CI_LOG_DIR}"/*/; do
            [[ -d "$lane_dir" ]] || continue
            local lane_name
            lane_name=$(basename "$lane_dir")
            echo "--- ${lane_name} ---"

            if [[ -f "${lane_dir}/lane.status" ]]; then
                cat "${lane_dir}/lane.status"
                echo ""
                continue
            fi

            for status_file in "${lane_dir}"/*.status; do
                [[ -f "$status_file" ]] || continue
                local mode_name
                mode_name=$(basename "$status_file" .log.status)
                printf "  %-20s %s\n" "$mode_name" "$(cat "$status_file")"
            done
            echo ""
        done
    } > "$summary_file"

    cat "$summary_file"
    log_info "Summary written to ${summary_file}"
}

# ── Main ───────────────────────────────────────────────────────────────

main() {
    local lane="both"
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lane)   lane="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            -h|--help)
                echo "Usage: $0 [--lane wan|tc|both] [--dry-run]"
                exit 0
                ;;
            *) log_error "Unknown argument: $1"; exit 1 ;;
        esac
    done

    if $dry_run; then
        echo "Regression matrix (12 modes):"
        for mode in "${MODES[@]}"; do
            local ab
            ab=$(extract_ab "$mode")
            local type="builtin"
            is_builtin "$ab" || type="backend"
            printf "  %-20s (%s)\n" "$mode" "$type"
        done
        echo ""
        echo "SIMULATE_WAN lane: config/3c1s3r1p.yml (builtin protocols only)"
        echo "tc/netem lane:     config/5c1s5r5p_local.yml (all protocols via Docker)"
        exit 0
    fi

    mkdir -p "$CI_LOG_DIR"
    log_info "CI regression smoke gate starting"
    log_info "Log directory: ${CI_LOG_DIR}"

    local exit_code=0

    if [[ "$lane" == "wan" || "$lane" == "both" ]]; then
        run_wan_lane || exit_code=1
    fi

    if [[ "$lane" == "tc" || "$lane" == "both" ]]; then
        run_tc_lane || exit_code=1
    fi

    generate_summary
    exit $exit_code
}

main "$@"
