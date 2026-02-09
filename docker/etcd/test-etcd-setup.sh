#!/bin/bash
# test-etcd-setup.sh - Validates etcd Docker test infrastructure.
#
# Runs without Docker or etcd. Checks that all config files, scripts,
# and Dockerfiles are properly formed and consistent.
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

check_file_exists() {
    local desc="$1"
    local path="$2"
    if [ -f "$path" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (missing: $path)"
        FAIL=$((FAIL + 1))
    fi
}

check_file_contains() {
    local desc="$1"
    local path="$2"
    local pattern="$3"
    if grep -q "$pattern" "$path" 2>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (pattern '$pattern' not found in $path)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Etcd Docker Test Infrastructure Validation ==="
echo ""

# --- 1. Required files ---
echo "1. Required Files"
check_file_exists "Dockerfile exists" "$SCRIPT_DIR/Dockerfile"
check_file_exists "docker-compose.yml exists" "$SCRIPT_DIR/docker-compose.yml"
check_file_exists "run-etcd-test.sh exists" "$SCRIPT_DIR/run-etcd-test.sh"
check_file_exists "run-etcd-test.sh is executable" "$SCRIPT_DIR/run-etcd-test.sh"
check "run-etcd-test.sh is executable" test -x "$SCRIPT_DIR/run-etcd-test.sh"
echo ""

# --- 2. Config files ---
echo "2. Config Files"
check_file_exists "Site config (1c1s3r1p.yml)" "$PROJECT_DIR/config/1c1s3r1p.yml"
check_file_exists "Mode config (none_etcd.yml)" "$PROJECT_DIR/config/none_etcd.yml"
check_file_exists "Benchmark config (rw_fixed.yml)" "$PROJECT_DIR/config/rw_fixed.yml"
echo ""

# --- 3. Config content validation ---
echo "3. Config Content"
check_file_contains "none_etcd.yml has ab: etcd" "$PROJECT_DIR/config/none_etcd.yml" "ab: etcd"
check_file_contains "rw_fixed.yml has workload: rw" "$PROJECT_DIR/config/rw_fixed.yml" "workload: rw"
check_file_contains "1c1s3r1p.yml has 3 servers" "$PROJECT_DIR/config/1c1s3r1p.yml" "s301"
check_file_contains "1c1s3r1p.yml has client" "$PROJECT_DIR/config/1c1s3r1p.yml" "c01"
check_file_contains "1c1s3r1p.yml maps to localhost" "$PROJECT_DIR/config/1c1s3r1p.yml" "localhost"
echo ""

# --- 4. Shell script syntax ---
echo "4. Script Syntax"
check "run-etcd-test.sh passes bash -n" bash -n "$SCRIPT_DIR/run-etcd-test.sh"
check "test-etcd-setup.sh passes bash -n" bash -n "$SCRIPT_DIR/test-etcd-setup.sh"
echo ""

# --- 5. Dockerfile validation ---
echo "5. Dockerfile Content"
check_file_contains "Dockerfile has multi-stage build" "$SCRIPT_DIR/Dockerfile" "FROM.*builder"
check_file_contains "Dockerfile installs etcd server" "$SCRIPT_DIR/Dockerfile" "ETCD_VERSION"
check_file_contains "Dockerfile builds etcd-cpp-apiv3" "$SCRIPT_DIR/Dockerfile" "etcd-cpp-apiv3"
check_file_contains "Dockerfile copies config" "$SCRIPT_DIR/Dockerfile" "config"
check_file_contains "Dockerfile uses WAF build" "$SCRIPT_DIR/Dockerfile" "waf"
echo ""

# --- 6. docker-compose.yml validation ---
echo "6. Docker Compose Content"
check_file_contains "docker-compose has etcd service" "$SCRIPT_DIR/docker-compose.yml" "etcd:"
check_file_contains "docker-compose has jetpack service" "$SCRIPT_DIR/docker-compose.yml" "jetpack-etcd:"
check_file_contains "docker-compose exposes port 2379" "$SCRIPT_DIR/docker-compose.yml" "2379"
echo ""

# --- 7. run-etcd-test.sh content validation ---
echo "7. Test Script Content"
check_file_contains "Script includes benchmark config (rw_fixed)" "$SCRIPT_DIR/run-etcd-test.sh" "rw_fixed"
check_file_contains "Script includes site config" "$SCRIPT_DIR/run-etcd-test.sh" "1c1s3r1p"
check_file_contains "Script includes mode config" "$SCRIPT_DIR/run-etcd-test.sh" "none_etcd"
check_file_contains "Script starts servers before client" "$SCRIPT_DIR/run-etcd-test.sh" "server_procs"
check_file_contains "Script validates etcd keys" "$SCRIPT_DIR/run-etcd-test.sh" "JetPack/"
check_file_contains "Script checks for crashes" "$SCRIPT_DIR/run-etcd-test.sh" "segfault\|FATAL"
check_file_contains "Script reports throughput" "$SCRIPT_DIR/run-etcd-test.sh" "throughput"
echo ""

# --- 8. Source code dependencies ---
echo "8. Source Code Dependencies"
check_file_exists "etcd_kv_table_handler.h" "$PROJECT_DIR/src/deptran/etcd_kv_table_handler.h"
check_file_exists "etcd_connection_thread_pool.h" "$PROJECT_DIR/src/deptran/etcd_connection_thread_pool.h"
check_file_exists "etcd_leader_watcher.h" "$PROJECT_DIR/src/deptran/etcd_leader_watcher.h"
check_file_exists "etcd/server.h" "$PROJECT_DIR/src/deptran/etcd/server.h"
check_file_exists "etcd/coordinator.cc" "$PROJECT_DIR/src/deptran/etcd/coordinator.cc"
check_file_exists "etcd/frame.cc" "$PROJECT_DIR/src/deptran/etcd/frame.cc"
check_file_exists "etcd/commo.cc" "$PROJECT_DIR/src/deptran/etcd/commo.cc"
check_file_exists "etcd/service.cc" "$PROJECT_DIR/src/deptran/etcd/service.cc"
check_file_exists "jm_file_signal.h" "$PROJECT_DIR/jm_file_signal.h"
echo ""

# --- Summary ---
echo "=== Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "RESULT: FAIL ($FAIL checks failed)"
    exit 1
else
    echo "RESULT: ALL CHECKS PASSED"
    exit 0
fi
