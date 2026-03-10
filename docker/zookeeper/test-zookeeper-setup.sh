#!/bin/bash
# test-zookeeper-setup.sh - Validates ZooKeeper Docker test infrastructure.
#
# Runs without Docker or ZooKeeper. Checks that all config files, scripts,
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

echo "=== ZooKeeper Docker Test Infrastructure Validation ==="
echo ""

# --- 1. Required files ---
echo "1. Required Files"
check_file_exists "Dockerfile exists" "$SCRIPT_DIR/Dockerfile"
check_file_exists "docker-compose.yml exists" "$SCRIPT_DIR/docker-compose.yml"
check_file_exists "run-zookeeper-test.sh exists" "$SCRIPT_DIR/run-zookeeper-test.sh"
check "run-zookeeper-test.sh is executable" test -x "$SCRIPT_DIR/run-zookeeper-test.sh"
echo ""

# --- 2. Config files ---
echo "2. Config Files"
check_file_exists "Site config (1c1s3r1p.yml)" "$PROJECT_DIR/config/1c1s3r1p.yml"
check_file_exists "Multi-process config (5c1s5r1p_zookeeper.yml)" "$PROJECT_DIR/config/5c1s5r1p_zookeeper.yml"
check_file_exists "Failover config (failover_zookeeper.yml)" "$PROJECT_DIR/config/failover_zookeeper.yml"
echo ""

# --- 3. Config content validation ---
echo "3. Config Content"
check_file_contains "1c1s3r1p.yml has 3 servers" "$PROJECT_DIR/config/1c1s3r1p.yml" "s301"
check_file_contains "1c1s3r1p.yml has client" "$PROJECT_DIR/config/1c1s3r1p.yml" "c01"
check_file_contains "1c1s3r1p.yml maps to localhost" "$PROJECT_DIR/config/1c1s3r1p.yml" "localhost"
check_file_contains "5c1s5r1p_zookeeper.yml has 5 servers" "$PROJECT_DIR/config/5c1s5r1p_zookeeper.yml" "s501"
check_file_contains "5c1s5r1p_zookeeper.yml has 5 clients" "$PROJECT_DIR/config/5c1s5r1p_zookeeper.yml" "c501"
check_file_contains "5c1s5r1p_zookeeper.yml has separate loopback IPs" "$PROJECT_DIR/config/5c1s5r1p_zookeeper.yml" "127.0.0.5"
check_file_contains "5c1s5r1p_zookeeper.yml maps hosts h1-h5" "$PROJECT_DIR/config/5c1s5r1p_zookeeper.yml" "h5:"
check_file_contains "failover_zookeeper.yml has failover method" "$PROJECT_DIR/config/failover_zookeeper.yml" "method: soft"
check_file_contains "failover_zookeeper.yml has run_interval" "$PROJECT_DIR/config/failover_zookeeper.yml" "run_interval:"
check_file_contains "failover_zookeeper.yml has stop_interval" "$PROJECT_DIR/config/failover_zookeeper.yml" "stop_interval:"
check_file_contains "failover_zookeeper.yml targets leader" "$PROJECT_DIR/config/failover_zookeeper.yml" "failserver: leader"
echo ""

# --- 4. Shell script syntax ---
echo "4. Script Syntax"
check "run-zookeeper-test.sh passes bash -n" bash -n "$SCRIPT_DIR/run-zookeeper-test.sh"
check "test-zookeeper-setup.sh passes bash -n" bash -n "$SCRIPT_DIR/test-zookeeper-setup.sh"
echo ""

# --- 5. Dockerfile validation ---
echo "5. Dockerfile Content"
check_file_contains "Dockerfile has multi-stage build" "$SCRIPT_DIR/Dockerfile" "FROM.*builder"
check_file_contains "Dockerfile builds ZooKeeper C client" "$SCRIPT_DIR/Dockerfile" "zookeeper-client-c"
check_file_contains "Dockerfile uses Maven for jute generation" "$SCRIPT_DIR/Dockerfile" "mvn generate-sources"
check_file_contains "Dockerfile installs ZooKeeper server" "$SCRIPT_DIR/Dockerfile" "ZOOKEEPER_VERSION"
check_file_contains "Dockerfile copies config" "$SCRIPT_DIR/Dockerfile" "config"
check_file_contains "Dockerfile uses WAF build" "$SCRIPT_DIR/Dockerfile" "waf"
check_file_contains "Dockerfile copies ZooKeeper libraries" "$SCRIPT_DIR/Dockerfile" "libzookeeper"
check_file_contains "Dockerfile installs JDK for Maven" "$SCRIPT_DIR/Dockerfile" "default-jdk"
check_file_contains "Dockerfile installs JRE for runtime" "$SCRIPT_DIR/Dockerfile" "default-jre"
echo ""

# --- 6. docker-compose.yml validation ---
echo "6. Docker Compose Content"
check_file_contains "docker-compose has zookeeper service" "$SCRIPT_DIR/docker-compose.yml" "zookeeper:"
check_file_contains "docker-compose has jetpack service" "$SCRIPT_DIR/docker-compose.yml" "jetpack-zookeeper:"
check_file_contains "docker-compose pins jetpack-zookeeper image tag" "$SCRIPT_DIR/docker-compose.yml" "image: jetpack-zookeeper"
check_file_contains "docker-compose exposes port 2181" "$SCRIPT_DIR/docker-compose.yml" "2181"
check_file_contains "docker-compose sets build context" "$SCRIPT_DIR/docker-compose.yml" "context:"
check_file_contains "docker-compose has healthcheck" "$SCRIPT_DIR/docker-compose.yml" "healthcheck"
echo ""

# --- 7. run-zookeeper-test.sh content validation ---
echo "7. Test Script Content (single mode)"
check_file_contains "Script references 1c1s3r1p config" "$SCRIPT_DIR/run-zookeeper-test.sh" "1c1s3r1p"
check_file_contains "Script starts embedded ZooKeeper" "$SCRIPT_DIR/run-zookeeper-test.sh" "start_embedded_zookeeper"
check_file_contains "Script uses zkServer.sh" "$SCRIPT_DIR/run-zookeeper-test.sh" "zkServer.sh"
check_file_contains "Script uses zoo.cfg config" "$SCRIPT_DIR/run-zookeeper-test.sh" "zoo.cfg"
check_file_contains "Script has run_single_process_test function" "$SCRIPT_DIR/run-zookeeper-test.sh" "run_single_process_test"
check_file_contains "Script has cleanup trap" "$SCRIPT_DIR/run-zookeeper-test.sh" "trap cleanup"
check_file_contains "Script uses ZooKeeper ruok health check" "$SCRIPT_DIR/run-zookeeper-test.sh" "ruok"
check_file_contains "Script passes -P localhost in single mode" "$SCRIPT_DIR/run-zookeeper-test.sh" '\-P localhost'
check_file_contains "Script passes log directory via -r" "$SCRIPT_DIR/run-zookeeper-test.sh" '\-r "\$LOG_DIR"'
echo ""

# --- 7b. Multi-process test mode ---
echo "7b. Test Script Content (multi mode)"
check_file_contains "Script has multi mode" "$SCRIPT_DIR/run-zookeeper-test.sh" "run_multi_process_test"
check_file_contains "Script references 5c1s5r1p_zookeeper config" "$SCRIPT_DIR/run-zookeeper-test.sh" "5c1s5r1p_zookeeper"
check_file_contains "Script has latency simulation (setup_latency)" "$SCRIPT_DIR/run-zookeeper-test.sh" "setup_latency"
check_file_contains "Script has latency cleanup (remove_latency)" "$SCRIPT_DIR/run-zookeeper-test.sh" "remove_latency"
check_file_contains "Script uses tc netem for latency" "$SCRIPT_DIR/run-zookeeper-test.sh" "netem delay"
check_file_contains "Script has LATENCY_MS env var" "$SCRIPT_DIR/run-zookeeper-test.sh" "LATENCY_MS"
check_file_contains "Dockerfile installs iproute2" "$SCRIPT_DIR/Dockerfile" "iproute2"
echo ""

# --- 7c. Recovery test mode ---
echo "7c. Test Script Content (recovery mode)"
check_file_contains "Script has recovery mode" "$SCRIPT_DIR/run-zookeeper-test.sh" "run_recovery_test"
check_file_contains "Script has ZooKeeper ensemble setup" "$SCRIPT_DIR/run-zookeeper-test.sh" "start_zookeeper_ensemble"
check_file_contains "Script has ZooKeeper leader detection" "$SCRIPT_DIR/run-zookeeper-test.sh" "get_zookeeper_leader"
check_file_contains "Script has ZooKeeper node kill function" "$SCRIPT_DIR/run-zookeeper-test.sh" "kill_zookeeper_node"
check_file_contains "Script has new leader wait function" "$SCRIPT_DIR/run-zookeeper-test.sh" "wait_zookeeper_new_leader"
check_file_contains "Script uses external recovery flow (no failover config)" "$SCRIPT_DIR/run-zookeeper-test.sh" "WITHOUT failover config"
check_file_contains "Script checks for recovery in logs" "$SCRIPT_DIR/run-zookeeper-test.sh" "JetpackRecoveryEntry"
check_file_contains "Script uses ZooKeeper srvr command for leader" "$SCRIPT_DIR/run-zookeeper-test.sh" "srvr"
check_file_contains "Script creates 3-node ensemble" "$SCRIPT_DIR/run-zookeeper-test.sh" "3-node ZooKeeper ensemble"
check_file_contains "Script uses myid for ensemble nodes" "$SCRIPT_DIR/run-zookeeper-test.sh" "myid"
check_file_contains "Script checks surviving ZooKeeper nodes" "$SCRIPT_DIR/run-zookeeper-test.sh" "surviving"
echo ""

# --- 8. Source code dependencies ---
echo "8. Source Code Dependencies"
check_file_exists "zookeeper_kv_table_handler.h" "$PROJECT_DIR/src/deptran/zookeeper_kv_table_handler.h"
check_file_exists "zookeeper_connection_thread_pool.h" "$PROJECT_DIR/src/deptran/zookeeper_connection_thread_pool.h"
check_file_exists "zookeeper_leader_watcher.h" "$PROJECT_DIR/src/deptran/zookeeper_leader_watcher.h"
check_file_exists "zookeeper/server.h" "$PROJECT_DIR/src/deptran/zookeeper/server.h"
check_file_exists "zookeeper/coordinator.cc" "$PROJECT_DIR/src/deptran/zookeeper/coordinator.cc"
check_file_exists "zookeeper/frame.cc" "$PROJECT_DIR/src/deptran/zookeeper/frame.cc"
check_file_exists "zookeeper/commo.cc" "$PROJECT_DIR/src/deptran/zookeeper/commo.cc"
check_file_exists "zookeeper/service.cc" "$PROJECT_DIR/src/deptran/zookeeper/service.cc"
check_file_exists "jm_file_signal.h" "$PROJECT_DIR/jm_file_signal.h"
echo ""

# --- 9. ZooKeeper third_party ---
echo "9. ZooKeeper Third-Party Dependencies"
check_file_exists "ZooKeeper C client CMakeLists.txt" "$PROJECT_DIR/third_party/zookeeper/zookeeper-client/zookeeper-client-c/CMakeLists.txt"
check_file_exists "build_zookeeper.sh" "$PROJECT_DIR/third_party/build_zookeeper.sh"
check "build_zookeeper.sh is executable" test -x "$PROJECT_DIR/third_party/build_zookeeper.sh"
echo ""

# --- 10. ZooKeeper leader watcher validation ---
echo "10. ZooKeeper Leader Watcher"
check_file_contains "ZookeeperLeaderWatcher class" "$PROJECT_DIR/src/deptran/zookeeper_leader_watcher.h" "class ZookeeperLeaderWatcher"
check_file_contains "Uses zoo_wexists for watches" "$PROJECT_DIR/src/deptran/zookeeper_leader_watcher.h" "zoo_wexists"
check_file_contains "Watches /JetPack/leader znode" "$PROJECT_DIR/src/deptran/zookeeper_leader_watcher.h" "/JetPack/leader"
check_file_contains "Detects ZOO_DELETED_EVENT" "$PROJECT_DIR/src/deptran/zookeeper_leader_watcher.h" "ZOO_DELETED_EVENT"
check_file_contains "Detects ZOO_CREATED_EVENT" "$PROJECT_DIR/src/deptran/zookeeper_leader_watcher.h" "ZOO_CREATED_EVENT"
check_file_contains "Signals via jm_file_signal" "$PROJECT_DIR/src/deptran/zookeeper_leader_watcher.h" "jm_signal::set_key"
check_file_contains "Has Start method" "$PROJECT_DIR/src/deptran/zookeeper_leader_watcher.h" "void Start()"
check_file_contains "Has Stop method" "$PROJECT_DIR/src/deptran/zookeeper_leader_watcher.h" "void Stop()"
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
