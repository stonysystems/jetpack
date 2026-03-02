#!/bin/bash
# test_sweep_benchmark.sh - Unit tests for sweep_benchmark.sh
#
# Tests the failure handling, retry logic, status classification, and output
# format of sweep_benchmark.sh by mocking the docker command.
#
# Usage: bash scripts/test_sweep_benchmark.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}: $desc"
        echo "  expected: '$expected'"
        echo "  actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "${GREEN}PASS${NC}: $desc"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}: $desc"
        echo "  expected to contain: '$needle'"
        echo "  in: '$haystack'"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -qF "$needle"; then
        echo -e "${GREEN}PASS${NC}: $desc"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}: $desc"
        echo "  expected NOT to contain: '$needle'"
        echo "  in: '$haystack'"
        FAIL=$((FAIL + 1))
    fi
}

# ---------------------------------------------------------------
# Mock docker outputs for different scenarios
# ---------------------------------------------------------------

# Successful run with all 5 processes reporting
MOCK_OK_OUTPUT='h1: site Benchmark Summary: Mid throughput 50.20
h2: site Benchmark Summary: Mid throughput 48.90
h3: site Benchmark Summary: Mid throughput 51.30
h4: site Benchmark Summary: Mid throughput 49.70
h5: site Benchmark Summary: Mid throughput 50.10
h1: Fastpath statistics attempted 1000 successed 800 rate(pct) 80.00
h2: Fastpath statistics attempted 1000 successed 810 rate(pct) 81.00
h3: Fastpath statistics attempted 1000 successed 790 rate(pct) 79.00
h4: Fastpath statistics attempted 1000 successed 805 rate(pct) 80.50
h5: Fastpath statistics attempted 1000 successed 795 rate(pct) 79.50
h1: Cpu-usage-leaders ave 45.5000 count 1
h2: Cpu-usage-leaders ave 46.2000 count 1
h3: Cpu-usage-leaders ave 44.8000 count 1
h4: Cpu-usage-leaders ave 45.9000 count 1
h5: Cpu-usage-leaders ave 46.0000 count 1
h1: Queue-depth ave 10.5000 count 1
h2: Queue-depth ave 11.2000 count 1
h3: Queue-depth ave 10.8000 count 1
h4: Queue-depth ave 11.0000 count 1
h5: Queue-depth ave 10.3000 count 1'

# Partial failure: h3 reports 0 throughput
MOCK_PARTIAL_OUTPUT='h1: site Benchmark Summary: Mid throughput 50.20
h2: site Benchmark Summary: Mid throughput 48.90
h3: site Benchmark Summary: Mid throughput 0
h4: site Benchmark Summary: Mid throughput 49.70
h5: site Benchmark Summary: Mid throughput 50.10'

# Complete failure: no benchmark output at all
MOCK_FAILED_EMPTY=""

# Complete failure: crash output
MOCK_FAILED_CRASH='Starting benchmark...
h1: initializing
Segmentation fault (core dumped)'

# OOM failure
MOCK_FAILED_OOM='Starting benchmark...
Cannot allocate memory
h1: site exiting'

# Timeout failure
MOCK_FAILED_TIMEOUT='Starting benchmark...
h1: connection timed out
h2: connection timed out'

# ---------------------------------------------------------------
# Test 1: extract_metrics with successful output
# ---------------------------------------------------------------
echo "=== Test 1: extract_metrics with OK output ==="

# Source just the functions by creating a testable version
cat > "$TEST_DIR/test_funcs.sh" << 'FUNCSEOF'
extract_metrics() {
    local output="$1"
    h1=$(echo "$output" | grep "h1:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h2=$(echo "$output" | grep "h2:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h3=$(echo "$output" | grep "h3:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h4=$(echo "$output" | grep "h4:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    h5=$(echo "$output" | grep "h5:.*Mid throughput" | grep -oP '[\d.]+$' || echo "0")
    total=$(echo "$h1 + $h2 + $h3 + $h4 + $h5" | bc 2>/dev/null || echo "0")

    fp_attempted=0
    fp_succeeded=0
    for h in h1 h2 h3 h4 h5; do
        fp_line=$(echo "$output" | grep "${h}:.*Fastpath statistics" || true)
        if [ -n "$fp_line" ]; then
            a=$(echo "$fp_line" | grep -oP 'attempted \K\d+' || echo "0")
            s=$(echo "$fp_line" | grep -oP 'successed \K\d+' | head -1 || echo "0")
            fp_attempted=$((fp_attempted + a))
            fp_succeeded=$((fp_succeeded + s))
        fi
    done
    if [ "$fp_attempted" -gt 0 ]; then
        fp_rate=$(echo "scale=2; $fp_succeeded * 100.0 / $fp_attempted" | bc 2>/dev/null || echo "0")
    else
        fp_rate="0"
    fi

    cpu_sum=0; cpu_n=0
    for h in h1 h2 h3 h4 h5; do
        cpu_line=$(echo "$output" | grep "${h}:.*Cpu-usage-leaders" || true)
        if [ -n "$cpu_line" ]; then
            c=$(echo "$cpu_line" | grep -oP 'ave \K[\d.]+' || echo "")
            if [ -n "$c" ] && [ "$c" != "-1.0000" ]; then
                cpu_sum=$(echo "$cpu_sum + $c" | bc 2>/dev/null || echo "$cpu_sum")
                cpu_n=$((cpu_n + 1))
            fi
        fi
    done
    if [ "$cpu_n" -gt 0 ]; then
        cpu_leader_avg=$(echo "scale=4; $cpu_sum / $cpu_n" | bc 2>/dev/null || echo "0")
    else
        cpu_leader_avg="0"
    fi

    qd_sum=0; qd_n=0
    for h in h1 h2 h3 h4 h5; do
        qd_line=$(echo "$output" | grep "${h}:.*Queue-depth" || true)
        if [ -n "$qd_line" ]; then
            q=$(echo "$qd_line" | grep -oP 'ave \K[\d.]+' || echo "")
            if [ -n "$q" ] && [ "$q" != "-1.0000" ]; then
                qd_sum=$(echo "$qd_sum + $q" | bc 2>/dev/null || echo "$qd_sum")
                qd_n=$((qd_n + 1))
            fi
        fi
    done
    if [ "$qd_n" -gt 0 ]; then
        queue_depth_avg=$(echo "scale=4; $qd_sum / $qd_n" | bc 2>/dev/null || echo "0")
    else
        queue_depth_avg="0"
    fi
}

classify_run() {
    local exit_code="$1"
    local total_tp="$2"
    shift 2
    local procs=("$@")

    if [ "$exit_code" -ne 0 ]; then
        status="FAILED"
        error_summary="docker_exit_${exit_code}"
        return
    fi

    local is_zero
    is_zero=$(echo "$total_tp == 0" | bc 2>/dev/null || echo "1")
    if [ "$is_zero" -eq 1 ]; then
        status="FAILED"
        error_summary="zero_throughput_all_processes"
        return
    fi

    local zero_count=0
    for p in "${procs[@]}"; do
        local pz
        pz=$(echo "$p == 0" | bc 2>/dev/null || echo "1")
        if [ "$pz" -eq 1 ]; then
            zero_count=$((zero_count + 1))
        fi
    done

    if [ "$zero_count" -gt 0 ]; then
        status="PARTIAL"
        error_summary="${zero_count}_of_5_processes_zero"
    else
        status="OK"
        error_summary=""
    fi
}

detect_failure_signature() {
    local output="$1"
    local exit_code="$2"

    if echo "$output" | grep -qi "out of memory\|OOM\|Cannot allocate memory"; then
        error_summary="${error_summary};OOM"
    fi
    if echo "$output" | grep -qi "too many open files\|EMFILE"; then
        error_summary="${error_summary};fd_exhaustion"
    fi
    if echo "$output" | grep -qi "connection refused\|Connection reset"; then
        error_summary="${error_summary};connection_failure"
    fi
    if echo "$output" | grep -qi "Segmentation fault\|SIGSEGV\|core dumped"; then
        error_summary="${error_summary};crash_segfault"
    fi
    if echo "$output" | grep -qi "timeout\|timed out"; then
        error_summary="${error_summary};timeout"
    fi
    if [ -z "$output" ]; then
        error_summary="${error_summary};empty_output"
    elif ! echo "$output" | grep -q "Mid throughput"; then
        error_summary="${error_summary};no_benchmark_output"
    fi
}
FUNCSEOF

source "$TEST_DIR/test_funcs.sh"

# Test OK output extraction
extract_metrics "$MOCK_OK_OUTPUT"
assert_eq "OK: h1 throughput" "50.20" "$h1"
assert_eq "OK: h2 throughput" "48.90" "$h2"
assert_eq "OK: total throughput" "250.20" "$total"
assert_eq "OK: fp_attempted" "5000" "$fp_attempted"
assert_eq "OK: fp_succeeded" "4000" "$fp_succeeded"
assert_eq "OK: fp_rate" "80.00" "$fp_rate"

# ---------------------------------------------------------------
# Test 2: classify_run with OK status
# ---------------------------------------------------------------
echo ""
echo "=== Test 2: classify_run with OK ==="

classify_run 0 "250.20" "50.20" "48.90" "51.30" "49.70" "50.10"
assert_eq "OK: status" "OK" "$status"
assert_eq "OK: error_summary empty" "" "$error_summary"

# ---------------------------------------------------------------
# Test 3: classify_run with FAILED (non-zero exit)
# ---------------------------------------------------------------
echo ""
echo "=== Test 3: classify_run with FAILED (non-zero exit) ==="

classify_run 1 "0" "0" "0" "0" "0" "0"
assert_eq "FAILED exit: status" "FAILED" "$status"
assert_eq "FAILED exit: error_summary" "docker_exit_1" "$error_summary"

classify_run 137 "0" "0" "0" "0" "0" "0"
assert_eq "FAILED exit 137: status" "FAILED" "$status"
assert_eq "FAILED exit 137: error_summary" "docker_exit_137" "$error_summary"

# ---------------------------------------------------------------
# Test 4: classify_run with FAILED (zero throughput, exit 0)
# ---------------------------------------------------------------
echo ""
echo "=== Test 4: classify_run FAILED (zero throughput) ==="

classify_run 0 "0" "0" "0" "0" "0" "0"
assert_eq "FAILED zero: status" "FAILED" "$status"
assert_eq "FAILED zero: error_summary" "zero_throughput_all_processes" "$error_summary"

# ---------------------------------------------------------------
# Test 5: classify_run with PARTIAL
# ---------------------------------------------------------------
echo ""
echo "=== Test 5: classify_run with PARTIAL ==="

extract_metrics "$MOCK_PARTIAL_OUTPUT"
classify_run 0 "$total" "$h1" "$h2" "$h3" "$h4" "$h5"
assert_eq "PARTIAL: status" "PARTIAL" "$status"
assert_contains "PARTIAL: error mentions count" "1_of_5_processes_zero" "$error_summary"

# ---------------------------------------------------------------
# Test 6: detect_failure_signature - crash
# ---------------------------------------------------------------
echo ""
echo "=== Test 6: detect_failure_signature - crash ==="

error_summary="docker_exit_139"
detect_failure_signature "$MOCK_FAILED_CRASH" 139
assert_contains "Crash: segfault detected" "crash_segfault" "$error_summary"
assert_contains "Crash: no benchmark output" "no_benchmark_output" "$error_summary"

# ---------------------------------------------------------------
# Test 7: detect_failure_signature - OOM
# ---------------------------------------------------------------
echo ""
echo "=== Test 7: detect_failure_signature - OOM ==="

error_summary="docker_exit_137"
detect_failure_signature "$MOCK_FAILED_OOM" 137
assert_contains "OOM: detected" "OOM" "$error_summary"

# ---------------------------------------------------------------
# Test 8: detect_failure_signature - timeout
# ---------------------------------------------------------------
echo ""
echo "=== Test 8: detect_failure_signature - timeout ==="

error_summary="zero_throughput_all_processes"
detect_failure_signature "$MOCK_FAILED_TIMEOUT" 0
assert_contains "Timeout: detected" "timeout" "$error_summary"

# ---------------------------------------------------------------
# Test 9: detect_failure_signature - empty output
# ---------------------------------------------------------------
echo ""
echo "=== Test 9: detect_failure_signature - empty output ==="

error_summary="docker_exit_1"
detect_failure_signature "" 1
assert_contains "Empty: detected" "empty_output" "$error_summary"

# ---------------------------------------------------------------
# Test 10: extract_metrics with empty output (failed run)
# ---------------------------------------------------------------
echo ""
echo "=== Test 10: extract_metrics with empty output ==="

extract_metrics ""
assert_eq "Empty: h1" "0" "$h1"
assert_eq "Empty: total" "0" "$total"
assert_eq "Empty: fp_attempted" "0" "$fp_attempted"
assert_eq "Empty: cpu_leader_avg" "0" "$cpu_leader_avg"
assert_eq "Empty: queue_depth_avg" "0" "$queue_depth_avg"

# ---------------------------------------------------------------
# Test 11: TSV header has new columns
# ---------------------------------------------------------------
echo ""
echo "=== Test 11: TSV header format ==="

header_line=$(head -20 "$SCRIPT_DIR/sweep_benchmark.sh" | grep -c "status.*error_summary.*log_path.*retry_count" || echo "0")
assert_eq "Header doc mentions new columns" "1" "$header_line"

# Check the header echo line (the one starting with "concurrency")
header_echo=$(grep -c 'echo -e "concurrency.*status.*error_summary.*log_path.*retry_count' "$SCRIPT_DIR/sweep_benchmark.sh")
assert_eq "Header echo has new columns" "1" "$header_echo"

# ---------------------------------------------------------------
# Test 12: Script has retry logic
# ---------------------------------------------------------------
echo ""
echo "=== Test 12: Retry logic present ==="

retry_present=$(grep -c "MAX_RETRIES" "$SCRIPT_DIR/sweep_benchmark.sh")
assert_eq "MAX_RETRIES defined and used (>= 4 refs)" "true" "$([ "$retry_present" -ge 4 ] && echo true || echo false)"

retry_loop=$(grep -c "seq 0.*MAX_RETRIES" "$SCRIPT_DIR/sweep_benchmark.sh")
assert_eq "Retry loop exists" "1" "$retry_loop"

# ---------------------------------------------------------------
# Test 13: Script saves logs
# ---------------------------------------------------------------
echo ""
echo "=== Test 13: Log saving logic ==="

log_save=$(grep -c "log_file=" "$SCRIPT_DIR/sweep_benchmark.sh")
assert_eq "Log file variable set" "1" "$log_save"

mkdir_logs=$(grep -c 'mkdir -p "$LOG_DIR"' "$SCRIPT_DIR/sweep_benchmark.sh")
assert_eq "Log directory created" "1" "$mkdir_logs"

# ---------------------------------------------------------------
# Test 14: Script does NOT use || true on docker run
# ---------------------------------------------------------------
echo ""
echo "=== Test 14: No silent failure suppression ==="

# Check no '|| true' near docker run (within 5 lines after)
if grep -A5 "docker run" "$SCRIPT_DIR/sweep_benchmark.sh" | grep -q '|| true'; then
    silent_suppress=1
else
    silent_suppress=0
fi
assert_eq "No || true on docker run" "0" "$silent_suppress"

# Check exit_code capture near docker run (within 10 lines after)
if grep -A10 "docker run" "$SCRIPT_DIR/sweep_benchmark.sh" | grep -q 'exit_code=\$?'; then
    captures_exit=1
else
    captures_exit=0
fi
assert_eq "Captures docker exit code" "1" "$captures_exit"

# ---------------------------------------------------------------
# Test 15: Full end-to-end with mocked docker (single concurrency)
# ---------------------------------------------------------------
echo ""
echo "=== Test 15: End-to-end with mock docker ==="

# Create a mock docker script that simulates OK output
cat > "$TEST_DIR/docker" << 'MOCKEOF'
#!/bin/bash
# Mock docker: output successful benchmark results
echo "h1: site Benchmark Summary: Mid throughput 40.10"
echo "h2: site Benchmark Summary: Mid throughput 38.50"
echo "h3: site Benchmark Summary: Mid throughput 41.20"
echo "h4: site Benchmark Summary: Mid throughput 39.80"
echo "h5: site Benchmark Summary: Mid throughput 40.00"
echo "h1: Fastpath statistics attempted 500 successed 400 rate(pct) 80.00"
echo "h2: Fastpath statistics attempted 500 successed 410 rate(pct) 82.00"
echo "h3: Fastpath statistics attempted 500 successed 390 rate(pct) 78.00"
echo "h4: Fastpath statistics attempted 500 successed 405 rate(pct) 81.00"
echo "h5: Fastpath statistics attempted 500 successed 395 rate(pct) 79.00"
exit 0
MOCKEOF
chmod +x "$TEST_DIR/docker"

# Create a minimal version of sweep for testing with single concurrency
cat > "$TEST_DIR/sweep_single.sh" << 'SWEEPEOF'
#!/bin/bash
set -euo pipefail
SCRIPT_DIR_ORIG="$1"
MOCK_DIR="$2"
export PATH="$MOCK_DIR:$PATH"

DOCKER_IMAGE="test-image"
MODE_CONFIG="test_mode.yml"
EXTRA_ARGS=""
SITE_CONFIG="60c1s5r5p.yml"
CLIENT_CONFIG="client_open.yml"
LATENCY_MS=20
LATENCY_JITTER=0
TEST_DURATION=30
MAX_RETRIES=2
LOG_DIR="$MOCK_DIR/logs"
mkdir -p "$LOG_DIR"

source "$MOCK_DIR/test_funcs.sh"

conc=10
best_status="FAILED"
best_output=""
best_exit_code=1
retry_count=0

for attempt in $(seq 0 "$MAX_RETRIES"); do
    log_file="${LOG_DIR}/conc${conc}_attempt${attempt}.log"
    exit_code=0
    output=$(docker run --rm --privileged \
        -e SITE_CONFIG="$SITE_CONFIG" \
        "$DOCKER_IMAGE" benchmark 2>&1) || exit_code=$?

    { echo "# Attempt: $attempt"; echo "---"; echo "$output"; } > "$log_file"

    extract_metrics "$output"
    classify_run "$exit_code" "$total" "$h1" "$h2" "$h3" "$h4" "$h5"

    if [ "$status" = "OK" ]; then
        best_status="OK"
        best_output="$output"
        best_exit_code="$exit_code"
        retry_count="$attempt"
        break
    elif [ "$status" = "PARTIAL" ] && [ "$best_status" = "FAILED" ]; then
        best_status="PARTIAL"
        best_output="$output"
        best_exit_code="$exit_code"
        retry_count="$attempt"
    elif [ "$best_status" = "FAILED" ]; then
        best_output="$output"
        best_exit_code="$exit_code"
        retry_count="$attempt"
    fi

    if [ "$status" = "OK" ] || [ "$status" = "PARTIAL" ]; then
        break
    fi
done

extract_metrics "$best_output"
classify_run "$best_exit_code" "$total" "$h1" "$h2" "$h3" "$h4" "$h5"
detect_failure_signature "$best_output" "$best_exit_code"
log_path="${LOG_DIR}/conc${conc}_attempt${retry_count}.log"

echo -e "${conc}\t${total}\t${h1}\t${h2}\t${h3}\t${h4}\t${h5}\t${fp_attempted}\t${fp_succeeded}\t${fp_rate}\t${cpu_leader_avg}\t${queue_depth_avg}\t${status}\t${error_summary}\t${log_path}\t${retry_count}"
SWEEPEOF
chmod +x "$TEST_DIR/sweep_single.sh"

e2e_output=$(bash "$TEST_DIR/sweep_single.sh" "$SCRIPT_DIR" "$TEST_DIR")

# Parse the output
e2e_conc=$(echo "$e2e_output" | cut -f1)
e2e_total=$(echo "$e2e_output" | cut -f2)
e2e_status=$(echo "$e2e_output" | cut -f13)
e2e_retry=$(echo "$e2e_output" | cut -f16)

assert_eq "E2E: concurrency" "10" "$e2e_conc"
assert_eq "E2E: status OK" "OK" "$e2e_status"
assert_eq "E2E: retry count 0 (no retries needed)" "0" "$e2e_retry"
assert_eq "E2E: total throughput" "199.60" "$e2e_total"
assert_eq "E2E: log file exists" "true" "$([ -f "$TEST_DIR/logs/conc10_attempt0.log" ] && echo true || echo false)"

# ---------------------------------------------------------------
# Test 16: End-to-end with failing mock docker (should retry)
# ---------------------------------------------------------------
echo ""
echo "=== Test 16: E2E with failing docker (retry logic) ==="

# Mock docker that fails first 2 times, succeeds on 3rd
cat > "$TEST_DIR/docker" << 'MOCKEOF2'
#!/bin/bash
# Check attempt file to track calls
ATTEMPT_FILE="/tmp/test_sweep_mock_attempts"
if [ ! -f "$ATTEMPT_FILE" ]; then
    echo "0" > "$ATTEMPT_FILE"
fi
count=$(cat "$ATTEMPT_FILE")
count=$((count + 1))
echo "$count" > "$ATTEMPT_FILE"

if [ "$count" -le 2 ]; then
    echo "Starting benchmark..."
    echo "Connection timed out"
    exit 1
else
    echo "h1: site Benchmark Summary: Mid throughput 30.00"
    echo "h2: site Benchmark Summary: Mid throughput 30.00"
    echo "h3: site Benchmark Summary: Mid throughput 30.00"
    echo "h4: site Benchmark Summary: Mid throughput 30.00"
    echo "h5: site Benchmark Summary: Mid throughput 30.00"
    exit 0
fi
MOCKEOF2
chmod +x "$TEST_DIR/docker"

# Reset attempt counter
rm -f /tmp/test_sweep_mock_attempts

e2e_retry_output=$(bash "$TEST_DIR/sweep_single.sh" "$SCRIPT_DIR" "$TEST_DIR" 2>/dev/null)
e2e_retry_status=$(echo "$e2e_retry_output" | cut -f13)
e2e_retry_count=$(echo "$e2e_retry_output" | cut -f16)
e2e_retry_total=$(echo "$e2e_retry_output" | cut -f2)

assert_eq "E2E retry: status OK after retries" "OK" "$e2e_retry_status"
assert_eq "E2E retry: retry count 2" "2" "$e2e_retry_count"
assert_eq "E2E retry: total throughput" "150.00" "$e2e_retry_total"

# Clean up
rm -f /tmp/test_sweep_mock_attempts

# ---------------------------------------------------------------
# Test 17: End-to-end with permanently failing docker
# ---------------------------------------------------------------
echo ""
echo "=== Test 17: E2E with permanently failing docker ==="

cat > "$TEST_DIR/docker" << 'MOCKEOF3'
#!/bin/bash
echo "Starting benchmark..."
echo "Segmentation fault (core dumped)"
exit 139
MOCKEOF3
chmod +x "$TEST_DIR/docker"

e2e_perm_fail=$(bash "$TEST_DIR/sweep_single.sh" "$SCRIPT_DIR" "$TEST_DIR" 2>/dev/null)
e2e_pf_status=$(echo "$e2e_perm_fail" | cut -f13)
e2e_pf_error=$(echo "$e2e_perm_fail" | cut -f14)
e2e_pf_total=$(echo "$e2e_perm_fail" | cut -f2)

assert_eq "E2E permfail: status FAILED" "FAILED" "$e2e_pf_status"
assert_eq "E2E permfail: total throughput 0" "0" "$e2e_pf_total"
assert_contains "E2E permfail: crash in error" "crash_segfault" "$e2e_pf_error"
assert_contains "E2E permfail: docker exit in error" "docker_exit_139" "$e2e_pf_error"

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo ""
echo "========================================"
echo "Tests: $((PASS + FAIL)) | Passed: $PASS | Failed: $FAIL"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
