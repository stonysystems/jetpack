#!/bin/bash
# test-mongodb-setup.sh - Validates MongoDB Docker test infrastructure.
#
# Runs without Docker or MongoDB. Checks that all config files, scripts,
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

echo "=== MongoDB Docker Test Infrastructure Validation ==="
echo ""

# --- 1. Required files ---
echo "1. Required Files"
check_file_exists "Dockerfile exists" "$SCRIPT_DIR/Dockerfile"
check_file_exists "docker-compose.yml exists" "$SCRIPT_DIR/docker-compose.yml"
check_file_exists "run-mongodb-test.sh exists" "$SCRIPT_DIR/run-mongodb-test.sh"
check "run-mongodb-test.sh is executable" test -x "$SCRIPT_DIR/run-mongodb-test.sh"
echo ""

# --- 2. Config files ---
echo "2. Config Files"
check_file_exists "Site config (1c1s3r1p.yml)" "$PROJECT_DIR/config/1c1s3r1p.yml"
check_file_exists "Mode config (none_mongodb.yml)" "$PROJECT_DIR/config/none_mongodb.yml"
check_file_exists "Benchmark config (rw_fixed.yml)" "$PROJECT_DIR/config/rw_fixed.yml"
echo ""

# --- 3. Config content validation ---
echo "3. Config Content"
check_file_contains "none_mongodb.yml has ab: mongodb" "$PROJECT_DIR/config/none_mongodb.yml" "ab: mongodb"
check_file_contains "rw_fixed.yml has workload: rw" "$PROJECT_DIR/config/rw_fixed.yml" "workload: rw"
check_file_contains "1c1s3r1p.yml has 3 servers" "$PROJECT_DIR/config/1c1s3r1p.yml" "s301"
check_file_contains "1c1s3r1p.yml has client" "$PROJECT_DIR/config/1c1s3r1p.yml" "c01"
check_file_contains "1c1s3r1p.yml maps to localhost" "$PROJECT_DIR/config/1c1s3r1p.yml" "localhost"
echo ""

# --- 4. Shell script syntax ---
echo "4. Script Syntax"
check "run-mongodb-test.sh passes bash -n" bash -n "$SCRIPT_DIR/run-mongodb-test.sh"
check "test-mongodb-setup.sh passes bash -n" bash -n "$SCRIPT_DIR/test-mongodb-setup.sh"
echo ""

# --- 5. Dockerfile validation ---
echo "5. Dockerfile Content"
check_file_contains "Dockerfile has multi-stage build" "$SCRIPT_DIR/Dockerfile" "FROM.*builder"
check_file_contains "Dockerfile builds mongo-c-driver" "$SCRIPT_DIR/Dockerfile" "mongo-c-driver"
check_file_contains "Dockerfile builds mongo-cxx-driver" "$SCRIPT_DIR/Dockerfile" "mongo-cxx-driver"
check_file_contains "Dockerfile installs MongoDB server" "$SCRIPT_DIR/Dockerfile" "MONGODB_VERSION"
check_file_contains "Dockerfile installs mongosh" "$SCRIPT_DIR/Dockerfile" "mongodb-mongosh"
check_file_contains "Dockerfile copies config" "$SCRIPT_DIR/Dockerfile" "config"
check_file_contains "Dockerfile uses WAF build" "$SCRIPT_DIR/Dockerfile" "waf"
check_file_contains "Dockerfile copies driver libraries" "$SCRIPT_DIR/Dockerfile" "libmongocxx"
check_file_contains "Dockerfile has healthcheck" "$SCRIPT_DIR/Dockerfile" "HEALTHCHECK"
echo ""

# --- 6. docker-compose.yml validation ---
echo "6. Docker Compose Content"
check_file_contains "docker-compose has mongodb service" "$SCRIPT_DIR/docker-compose.yml" "mongodb:"
check_file_contains "docker-compose has jetpack service" "$SCRIPT_DIR/docker-compose.yml" "jetpack-mongodb:"
check_file_contains "docker-compose exposes port 27017" "$SCRIPT_DIR/docker-compose.yml" "27017"
check_file_contains "docker-compose sets build context" "$SCRIPT_DIR/docker-compose.yml" "context:"
echo ""

# --- 7. run-mongodb-test.sh content validation ---
echo "7. Test Script Content (single mode)"
check_file_contains "Script includes benchmark config (rw_fixed)" "$SCRIPT_DIR/run-mongodb-test.sh" "rw_fixed"
check_file_contains "Script includes site config" "$SCRIPT_DIR/run-mongodb-test.sh" "1c1s3r1p"
check_file_contains "Script includes mode config" "$SCRIPT_DIR/run-mongodb-test.sh" "none_mongodb"
check_file_contains "Script starts servers before client" "$SCRIPT_DIR/run-mongodb-test.sh" "server_procs"
check_file_contains "Script validates MongoDB documents" "$SCRIPT_DIR/run-mongodb-test.sh" "JetPack"
check_file_contains "Script checks for crashes" "$SCRIPT_DIR/run-mongodb-test.sh" "segfault\|FATAL"
check_file_contains "Script reports throughput" "$SCRIPT_DIR/run-mongodb-test.sh" "throughput"
check_file_contains "Script starts embedded MongoDB" "$SCRIPT_DIR/run-mongodb-test.sh" "start_embedded_mongodb"
check_file_contains "Script verifies MongoDB read/write" "$SCRIPT_DIR/run-mongodb-test.sh" "verify_mongodb_rw"
check_file_contains "Script uses mongosh for verification" "$SCRIPT_DIR/run-mongodb-test.sh" "mongosh"
check_file_contains "Script launches 3 server replicas" "$SCRIPT_DIR/run-mongodb-test.sh" 's101.*s201.*s301'
check_file_contains "Script launches 1 client" "$SCRIPT_DIR/run-mongodb-test.sh" 'client_procs.*c01'
check_file_contains "Script checks KVTable collection" "$SCRIPT_DIR/run-mongodb-test.sh" "KVTable"
check_file_contains "Script has run_single_process_test function" "$SCRIPT_DIR/run-mongodb-test.sh" "run_single_process_test"
check_file_contains "Script has cleanup trap" "$SCRIPT_DIR/run-mongodb-test.sh" "trap cleanup"
check_file_contains "Script validates 4 processes" "$SCRIPT_DIR/run-mongodb-test.sh" "All 4 processes"
echo ""

# --- 8. Source code dependencies ---
echo "8. Source Code Dependencies"
check_file_exists "mongodb_kv_table_handler.h" "$PROJECT_DIR/src/deptran/mongodb_kv_table_handler.h"
check_file_exists "mongodb_connection_thread_pool.h" "$PROJECT_DIR/src/deptran/mongodb_connection_thread_pool.h"
check_file_exists "mongodb_leader_watcher.h" "$PROJECT_DIR/src/deptran/mongodb_leader_watcher.h"
check_file_exists "mongodb/server.h" "$PROJECT_DIR/src/deptran/mongodb/server.h"
check_file_exists "mongodb/coordinator.cc" "$PROJECT_DIR/src/deptran/mongodb/coordinator.cc"
check_file_exists "mongodb/frame.cc" "$PROJECT_DIR/src/deptran/mongodb/frame.cc"
check_file_exists "mongodb/commo.cc" "$PROJECT_DIR/src/deptran/mongodb/commo.cc"
check_file_exists "mongodb/service.cc" "$PROJECT_DIR/src/deptran/mongodb/service.cc"
check_file_exists "jm_file_signal.h" "$PROJECT_DIR/jm_file_signal.h"
echo ""

# --- 9. MongoDB driver third_party ---
echo "9. MongoDB Driver Third-Party Dependencies"
check_file_exists "mongo-c-driver CMakeLists.txt" "$PROJECT_DIR/third_party/mongo-c-driver/CMakeLists.txt"
check_file_exists "mongo-cxx-driver CMakeLists.txt" "$PROJECT_DIR/third_party/mongo-cxx-driver/CMakeLists.txt"
check_file_exists "build_mongodb.sh" "$PROJECT_DIR/third_party/build_mongodb.sh"
echo ""

# --- 10. MongoDB leader watcher validation ---
echo "10. MongoDB Leader Watcher"
check_file_contains "MongodbLeaderWatcher class" "$PROJECT_DIR/src/deptran/mongodb_leader_watcher.h" "class MongodbLeaderWatcher"
check_file_contains "Uses APM topology_changed" "$PROJECT_DIR/src/deptran/mongodb_leader_watcher.h" "on_topology_changed"
check_file_contains "Detects ReplicaSetWithPrimary" "$PROJECT_DIR/src/deptran/mongodb_leader_watcher.h" "ReplicaSetWithPrimary"
check_file_contains "Detects ReplicaSetNoPrimary" "$PROJECT_DIR/src/deptran/mongodb_leader_watcher.h" "ReplicaSetNoPrimary"
check_file_contains "Signals via jm_file_signal" "$PROJECT_DIR/src/deptran/mongodb_leader_watcher.h" "jm_signal::set_key"
check_file_contains "Finds RSPrimary server" "$PROJECT_DIR/src/deptran/mongodb_leader_watcher.h" "RSPrimary"
check_file_contains "Has Start method" "$PROJECT_DIR/src/deptran/mongodb_leader_watcher.h" "void Start()"
check_file_contains "Has Stop method" "$PROJECT_DIR/src/deptran/mongodb_leader_watcher.h" "void Stop()"
check_file_contains "s_main.cc integrates MongodbLeaderWatcher" "$PROJECT_DIR/src/deptran/s_main.cc" "mongodb_leader_watcher_g"
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
