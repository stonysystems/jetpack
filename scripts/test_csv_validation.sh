#!/usr/bin/env bash
# Tests for CSV presence validation logic in 10-run_all.sh and run_spot_check.sh.
#
# These tests verify that the success-check blocks correctly detect
# missing CSV files after scp, in addition to the existing .res checks.
#
# Usage: bash scripts/test_csv_validation.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

assert_eq() {
    local test_name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $test_name"
        ((PASS++))
    else
        echo "FAIL: $test_name (expected='$expected', actual='$actual')"
        ((FAIL++))
    fi
}

assert_contains() {
    local test_name="$1" expected_substr="$2" actual="$3"
    if [[ "$actual" == *"$expected_substr"* ]]; then
        echo "PASS: $test_name"
        ((PASS++))
    else
        echo "FAIL: $test_name (expected to contain '$expected_substr', got '$actual')"
        ((FAIL++))
    fi
}

# Create a temp directory for test data
TMPDIR_TEST=$(mktemp -d)
trap "rm -rf '$TMPDIR_TEST'" EXIT

# -------------------------------------------------------------------
# Helper: create a .res file with controlled content
# -------------------------------------------------------------------
make_res() {
    local path="$1"
    local mid_tp="${2:-1500.0}"
    local has_dump="${3:-true}"
    local has_error="${4:-false}"

    {
        echo "I [s_main.cc:432] 2026-03-23 10:00:00.000 | PWD : /home/user"
        echo "I | All-efficient-attempts           statistics   count     5000"
        if [[ "$mid_tp" != "0" ]]; then
            echo "Mid throughput is $mid_tp"
        fi
        if [[ "$has_dump" == "true" ]]; then
            echo "Dumped to results/recent_csv/test.csv with 5000 lines"
        fi
        if [[ "$has_error" == "true" ]]; then
            echo "generic server error"
        fi
        echo "I | server_shutdown"
    } > "$path"
}

# -------------------------------------------------------------------
# Helper: simulate the success-check logic from 10-run_all.sh
# This is extracted from the script for unit testing.
# -------------------------------------------------------------------
check_success() {
    local exp_dir="$1"
    local exp_name="$2"
    local replica="$3"
    local workload="${4:-rw_1000000}"

    local to_check_file="${exp_dir}/${exp_name}-${replica}.res"
    local status=0
    local fail_reason=""

    if [[ ! -f "$to_check_file" ]]; then
        echo "missing file"
        return 1
    fi

    local file_size
    file_size=$(stat -c%s "$to_check_file" 2>/dev/null || echo 0)
    local MAX_RES_SIZE_BYTES=$((50 * 1024 * 1024))
    if [[ "$file_size" -gt "$MAX_RES_SIZE_BYTES" ]]; then
        echo "oversized file"
        return 1
    fi

    if grep -q "Mid throughput is" "$to_check_file" && \
       grep -q "Dumped to" "$to_check_file" && \
       ! grep -q "generic server error" "$to_check_file"; then
        local mid_tp
        mid_tp=$(grep -m1 "Mid throughput is" "$to_check_file" | awk '{print $NF}' || echo 0)
        mid_tp=${mid_tp:-0}
        if [[ "$workload" == "rw_1000000" ]]; then
            if [[ "$(printf '%.0f' "${mid_tp}" 2>/dev/null || echo 0)" -lt 1 ]]; then
                echo "low throughput (${mid_tp})"
                return 1
            fi
        fi
        # CSV presence check (matches the new code in 10-run_all.sh)
        local csv_file="${exp_dir}/${exp_name}-${replica}.csv"
        if [[ ! -f "$csv_file" ]]; then
            echo "csv_missing_after_scp"
            return 1
        fi
    else
        echo "missing success markers"
        return 1
    fi

    echo "success"
    return 0
}


# ===================================================================
# Test 1: Complete run with .res and .csv — should succeed
# ===================================================================
echo "=== Test 1: Complete run with .res and .csv ==="
test_dir="$TMPDIR_TEST/test1"
mkdir -p "$test_dir"
make_res "$test_dir/exp-zoo0.res" "1500.0" "true"
echo "col1,col2" > "$test_dir/exp-zoo0.csv"
echo "1,2" >> "$test_dir/exp-zoo0.csv"
result=$(check_success "$test_dir" "exp" "zoo0" "rw_1000000")
assert_eq "complete run succeeds" "success" "$result"

# ===================================================================
# Test 2: .res present with "Dumped to" but CSV missing — should fail
# ===================================================================
echo ""
echo "=== Test 2: .res present but CSV missing ==="
test_dir="$TMPDIR_TEST/test2"
mkdir -p "$test_dir"
make_res "$test_dir/exp-zoo0.res" "1500.0" "true"
# No .csv file created
result=$(check_success "$test_dir" "exp" "zoo0" "rw_1000000" || true)
assert_eq "csv_missing detected" "csv_missing_after_scp" "$result"

# ===================================================================
# Test 3: .res missing — should fail with missing file
# ===================================================================
echo ""
echo "=== Test 3: .res file missing ==="
test_dir="$TMPDIR_TEST/test3"
mkdir -p "$test_dir"
result=$(check_success "$test_dir" "exp" "zoo0" "rw_1000000" || true)
assert_eq "missing res detected" "missing file" "$result"

# ===================================================================
# Test 4: .res present but no "Dumped to" — should fail
# ===================================================================
echo ""
echo "=== Test 4: .res without Dumped to line ==="
test_dir="$TMPDIR_TEST/test4"
mkdir -p "$test_dir"
make_res "$test_dir/exp-zoo0.res" "1500.0" "false"
result=$(check_success "$test_dir" "exp" "zoo0" "rw_1000000" || true)
assert_eq "missing success markers detected" "missing success markers" "$result"

# ===================================================================
# Test 5: Low throughput — should fail
# ===================================================================
echo ""
echo "=== Test 5: Low throughput ==="
test_dir="$TMPDIR_TEST/test5"
mkdir -p "$test_dir"
make_res "$test_dir/exp-zoo0.res" "0.001" "true"
echo "col1,col2" > "$test_dir/exp-zoo0.csv"
result=$(check_success "$test_dir" "exp" "zoo0" "rw_1000000" || true)
assert_contains "low throughput detected" "low throughput" "$result"

# ===================================================================
# Test 6: Low throughput on non-rw_1000000 workload — should succeed
# ===================================================================
echo ""
echo "=== Test 6: Low throughput on zipf workload (OK) ==="
test_dir="$TMPDIR_TEST/test6"
mkdir -p "$test_dir"
make_res "$test_dir/exp-zoo0.res" "0.001" "true"
echo "col1,col2" > "$test_dir/exp-zoo0.csv"
result=$(check_success "$test_dir" "exp" "zoo0" "rw_100" || true)
assert_eq "low throughput on non-rw_1000000 succeeds" "success" "$result"

# ===================================================================
# Test 7: Generic server error — should fail
# ===================================================================
echo ""
echo "=== Test 7: Generic server error ==="
test_dir="$TMPDIR_TEST/test7"
mkdir -p "$test_dir"
make_res "$test_dir/exp-zoo0.res" "1500.0" "true" "true"
echo "col1,col2" > "$test_dir/exp-zoo0.csv"
result=$(check_success "$test_dir" "exp" "zoo0" "rw_1000000" || true)
assert_eq "server error detected" "missing success markers" "$result"

# ===================================================================
# Test 8: Verify sync command is present in 10-run_all.sh
# ===================================================================
echo ""
echo "=== Test 8: sync command present in 10-run_all.sh ==="
if grep -q 'ssh.*"sync"' "$SCRIPT_DIR/10-run_all.sh"; then
    assert_eq "sync in 10-run_all.sh" "found" "found"
else
    assert_eq "sync in 10-run_all.sh" "found" "missing"
fi

# ===================================================================
# Test 9: Verify sync command is present in run_spot_check.sh
# ===================================================================
echo ""
echo "=== Test 9: sync command present in run_spot_check.sh ==="
if grep -q 'ssh.*"sync"' "$SCRIPT_DIR/run_spot_check.sh"; then
    assert_eq "sync in run_spot_check.sh" "found" "found"
else
    assert_eq "sync in run_spot_check.sh" "found" "missing"
fi

# ===================================================================
# Test 10: Verify csv_missing_after_scp check in 10-run_all.sh
# ===================================================================
echo ""
echo "=== Test 10: csv_missing check present in 10-run_all.sh ==="
if grep -q 'csv_missing_after_scp' "$SCRIPT_DIR/10-run_all.sh"; then
    assert_eq "csv_missing in 10-run_all.sh" "found" "found"
else
    assert_eq "csv_missing in 10-run_all.sh" "found" "missing"
fi

# ===================================================================
# Test 11: Verify csv_missing_after_scp check in run_spot_check.sh
# ===================================================================
echo ""
echo "=== Test 11: csv_missing check present in run_spot_check.sh ==="
if grep -q 'csv_missing_after_scp' "$SCRIPT_DIR/run_spot_check.sh"; then
    assert_eq "csv_missing in run_spot_check.sh" "found" "found"
else
    assert_eq "csv_missing in run_spot_check.sh" "found" "missing"
fi

# ===================================================================
# Test 12: Verify sleep ≥ 3 after sync in 10-run_all.sh
# ===================================================================
echo ""
echo "=== Test 12: sleep >=3 after sync in 10-run_all.sh ==="
# Check that there's a sleep with value >= 3 near the sync
if grep -A3 'ssh.*"sync"' "$SCRIPT_DIR/10-run_all.sh" | grep -qE 'sleep [3-9]'; then
    assert_eq "sleep >=3 in 10-run_all.sh" "found" "found"
else
    assert_eq "sleep >=3 in 10-run_all.sh" "found" "missing"
fi

# ===================================================================
# Summary
# ===================================================================
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
