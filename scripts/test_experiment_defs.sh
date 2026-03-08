#!/bin/bash
# test_experiment_defs.sh — Unit tests for experiment_defs.sh
#
# Usage: bash scripts/test_experiment_defs.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/experiment_defs.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc"
        echo "  expected: $expected"
        echo "  actual:   $actual"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc"
        echo "  expected to contain: $needle"
        echo "  actual: $haystack"
    fi
}

# --- mode_flag_for ---
assert_eq "mode_flag original" "0" "$(mode_flag_for original)"
assert_eq "mode_flag none" "0" "$(mode_flag_for none)"
assert_eq "mode_flag rule100" "100" "$(mode_flag_for rule100)"
assert_eq "mode_flag fp100" "100" "$(mode_flag_for fp100)"
assert_eq "mode_flag adaptive" "101" "$(mode_flag_for adaptive)"
assert_eq "mode_flag rule101" "101" "$(mode_flag_for rule101)"
assert_eq "mode_flag passthrough" "42" "$(mode_flag_for 42)"

# --- mode_config_for ---
assert_eq "mode_config original etcd" "none_etcd.yml" "$(mode_config_for original etcd)"
assert_eq "mode_config adaptive mongodb" "rule_mongodb.yml" "$(mode_config_for adaptive mongodb)"
assert_eq "mode_config fp100 zookeeper" "rule_zookeeper.yml" "$(mode_config_for fp100 zookeeper)"

# --- derive_client_config ---
# With real config dir
CFG_DIR="${SCRIPT_DIR}/../config"
assert_eq "client_config copilot" "client_open_copilot.yml" "$(derive_client_config rule_copilot "$CFG_DIR")"
assert_eq "client_config raft" "client_open_raft.yml" "$(derive_client_config none_raft "$CFG_DIR")"
# etcd has no specialized client config, should fall back
assert_eq "client_config etcd fallback" "client_open.yml" "$(derive_client_config rule_etcd "$CFG_DIR")"
# No underscore in protocol name
assert_eq "client_config no-underscore" "client_open.yml" "$(derive_client_config standalone "$CFG_DIR")"

# --- build_deptran_cmd ---
cmd=$(build_deptran_cmd "/repo" "none_raft" "60c1s5r10p" "rw_1000000" "concurrent_100" "0" "30" "YCSB_A" "")
assert_contains "cmd has cd" "cd /repo" "$cmd"
assert_contains "cmd has protocol" "-f config/none_raft.yml" "$cmd"
assert_contains "cmd has site" "-f config/60c1s5r10p.yml" "$cmd"
assert_contains "cmd has workload" "-f config/rw_1000000.yml" "$cmd"
assert_contains "cmd has concurrent" "-f config/concurrent_100.yml" "$cmd"
assert_contains "cmd has ycsb" "-f config/YCSB_A.yml" "$cmd"
assert_contains "cmd has mode" "-m 0" "$cmd"
assert_contains "cmd has duration" "-d 30" "$cmd"

# With failover
cmd_fo=$(build_deptran_cmd "/repo" "rule_etcd" "5c1s5r5p" "rw_1" "concurrent_1" "101" "70" "" "true")
assert_contains "failover cmd has failover.yml" "-f config/failover.yml" "$cmd_fo"

# Without ycsb
cmd_no_ycsb=$(build_deptran_cmd "/repo" "rule_etcd" "5c1s5r5p" "rw_1" "concurrent_1" "101" "30" "" "")
# Should not have YCSB
if [[ "$cmd_no_ycsb" != *"YCSB"* ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: cmd without ycsb should not contain YCSB"
fi

# --- build_result_prefix ---
assert_eq "result_prefix" "none_raft-60c1s5r10p-rw_1000000-concurrent_100-0-YCSB_A" \
    "$(build_result_prefix none_raft 60c1s5r10p rw_1000000 concurrent_100 0 YCSB_A)"

# --- concs_array_for ---
assert_eq "concs raft" "RAFT_CONCS" "$(concs_array_for none_raft)"
assert_eq "concs copilot" "COPILOT_CONCS" "$(concs_array_for rule_copilot)"
assert_eq "concs mencius" "MENCIUS_CONCS" "$(concs_array_for rule_mencius)"
assert_eq "concs mongodb" "MONGODB_CONCS" "$(concs_array_for none_mongodb)"
assert_eq "concs etcd" "DOCKER_SWEEP_CONCS" "$(concs_array_for rule_etcd)"
assert_eq "concs zookeeper" "DOCKER_SWEEP_CONCS" "$(concs_array_for none_zookeeper)"

# --- generate_legacy_matrix ---
generate_legacy_matrix "concurrency_sweep" "60c1s5r10p"
legacy_count=${#GENERATED_CONFIGS[@]}
if [[ $legacy_count -gt 200 ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: legacy concurrency_sweep should generate >200 configs, got $legacy_count"
fi

# --- generate_current_matrix ---
generate_current_matrix "concurrency_sweep" "60c1s5r5p"
current_count=${#GENERATED_CONFIGS[@]}
# 3 backends × 3 modes × 11 concs = 99
assert_eq "current sweep count" "99" "$current_count"

generate_current_matrix "concurrency_sweep" "60c1s5r5p" "etcd"
etcd_only=${#GENERATED_CONFIGS[@]}
# 1 backend × 3 modes × 11 concs = 33
assert_eq "current etcd-only count" "33" "$etcd_only"

generate_current_matrix "single_point" "5c1s5r5p"
single_count=${#GENERATED_CONFIGS[@]}
# 3 backends × 3 modes = 9
assert_eq "current single_point count" "9" "$single_count"

# --- Array consistency checks ---
assert_eq "legacy jetpack count" "${#LEGACY_ORIGIN_PROTOCOLS[@]}" "${#LEGACY_JETPACK_PROTOCOLS[@]}"
assert_eq "current backends count" "${#CURRENT_BACKENDS[@]}" "${#CURRENT_DOCKER_IMAGES[@]}"
assert_eq "current origin count" "${#CURRENT_BACKENDS[@]}" "${#CURRENT_ORIGIN_PROTOCOLS[@]}"
assert_eq "current jetpack count" "${#CURRENT_BACKENDS[@]}" "${#CURRENT_JETPACK_PROTOCOLS[@]}"

# --- Docker backend definitions ---
assert_eq "failover config etcd" "failover_etcd.yml" "${FAILOVER_CONFIGS[etcd]}"
assert_eq "failover config mongodb" "failover_mongodb.yml" "${FAILOVER_CONFIGS[mongodb]}"
assert_eq "failover config zookeeper" "failover_zookeeper.yml" "${FAILOVER_CONFIGS[zookeeper]}"
assert_eq "compose file etcd" "docker/etcd/docker-compose.yml" "${DOCKER_COMPOSE_FILES[etcd]}"
assert_eq "test script mongodb" "docker/mongodb/run-mongodb-test.sh" "${DOCKER_TEST_SCRIPTS[mongodb]}"
assert_eq "aws restart mongodb" "scripts/95-restart_mongodb.sh" "${AWS_RESTART_SCRIPTS[mongodb]}"
# etcd and zookeeper have no AWS restart helpers
assert_eq "aws restart etcd unset" "" "${AWS_RESTART_SCRIPTS[etcd]:-}"
assert_eq "docker test modes count" "4" "${#DOCKER_TEST_MODES[@]}"

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
echo "All tests passed."
