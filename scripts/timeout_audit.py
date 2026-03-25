#!/usr/bin/env python3
"""
Audit whether TIMEOUT_SEC=180 in scripts/10-run_all.sh is sufficient.

Scans completed .res files to extract wall-clock durations (first timestamp
to last timestamp), then compares against the configured timeout.  Also
cross-references with the CSV audit to identify whether any timeout-classified
failures are genuine time-limit violations vs. other startup/runtime failures.

Outputs:
  - <result_dir>/timeout_audit.json

Usage:
    python3 scripts/timeout_audit.py <result_dir> [--timeout 180]
"""

import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime

TIMESTAMP_RE = re.compile(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})")
MID_THROUGHPUT_RE = re.compile(r"Mid throughput is ([\d.]+)")
DUMP_RE = re.compile(r"Dumped to .+\.csv")

DEFAULT_TIMEOUT = 180  # seconds
DEFAULT_SERVERS = [f"zoo{i}" for i in range(5)]

# Bytes to read from head/tail for timestamp extraction
_HEAD_BYTES = 4096
_TAIL_BYTES = 4096


def extract_wall_time(res_path):
    """Extract wall-clock duration from a .res file.

    Returns dict with:
      wall_time_s: float or None (seconds from first to last timestamp)
      completed: bool (has Mid throughput line)
      has_csv_dump: bool (has Dumped to line)
      file_size: int
      first_ts: str or None
      last_ts: str or None
      n_lines_approx: int (approximate line count from file size)
    """
    result = {
        "wall_time_s": None,
        "completed": False,
        "has_csv_dump": False,
        "file_size": 0,
        "first_ts": None,
        "last_ts": None,
    }

    if not os.path.isfile(res_path):
        return result

    file_size = os.path.getsize(res_path)
    result["file_size"] = file_size

    if file_size == 0:
        return result

    with open(res_path, "rb") as f:
        head = f.read(min(_HEAD_BYTES, file_size)).decode("utf-8", errors="replace")
        if file_size > _HEAD_BYTES + _TAIL_BYTES:
            f.seek(-_TAIL_BYTES, 2)
            tail = f.read(_TAIL_BYTES).decode("utf-8", errors="replace")
        elif file_size > _HEAD_BYTES:
            f.seek(-min(_TAIL_BYTES, file_size), 2)
            tail = f.read().decode("utf-8", errors="replace")
        else:
            tail = head

    result["completed"] = bool(MID_THROUGHPUT_RE.search(tail))
    result["has_csv_dump"] = bool(DUMP_RE.search(tail))

    first_match = TIMESTAMP_RE.search(head)
    tail_matches = TIMESTAMP_RE.findall(tail)

    if first_match:
        result["first_ts"] = first_match.group(1)
    if tail_matches:
        result["last_ts"] = tail_matches[-1]

    if result["first_ts"] and result["last_ts"]:
        t0 = datetime.strptime(result["first_ts"], "%Y-%m-%d %H:%M:%S.%f")
        t1 = datetime.strptime(result["last_ts"], "%Y-%m-%d %H:%M:%S.%f")
        result["wall_time_s"] = (t1 - t0).total_seconds()

    return result


def collect_durations(result_dir, servers=None):
    """Scan result directory for all .res files and extract durations.

    Returns list of dicts:
      [{protocol, concurrency, mode, server, wall_time_s, completed, ...}, ...]
    """
    if servers is None:
        servers = DEFAULT_SERVERS

    server_pattern = "|".join(re.escape(s) for s in servers)
    file_re = re.compile(
        rf"^(.+)-30c1s5r5p-zoo-rw_\d+-"
        rf"(concurrent_\d+)-(\d+)-YCSB_[A-Z]-({server_pattern})\.res$"
    )

    results = []
    for fname in os.listdir(result_dir):
        m = file_re.match(fname)
        if not m:
            continue
        protocol, concurrent, mode, server = m.groups()
        path = os.path.join(result_dir, fname)
        timing = extract_wall_time(path)
        timing["protocol"] = protocol
        timing["concurrency"] = int(concurrent.split("_")[1])
        timing["mode"] = mode
        timing["server"] = server
        timing["filename"] = fname
        results.append(timing)

    return results


def classify_timeout_risk(durations, timeout_sec):
    """Classify each run's relationship to the timeout.

    Returns dict with:
      total_runs: int
      completed_runs: int
      incomplete_runs: int
      max_wall_time_s: float
      timeout_sec: int
      headroom_pct: float (how much spare capacity, as percentage)
      at_risk_runs: list of runs where wall_time > 0.8 * timeout
      genuine_timeouts: list of runs that appear killed by timeout
      startup_failures: list of incomplete runs with very short wall time
      per_protocol_max: {protocol: max_wall_time}
    """
    completed = [d for d in durations if d["completed"]]
    incomplete = [d for d in durations if not d["completed"]]

    max_wt = max((d["wall_time_s"] for d in completed if d["wall_time_s"] is not None), default=0)

    at_risk = [d for d in completed
               if d["wall_time_s"] is not None and d["wall_time_s"] > 0.8 * timeout_sec]

    # A genuine timeout: incomplete run with wall_time close to or exceeding timeout
    genuine_timeouts = [d for d in incomplete
                        if d["wall_time_s"] is not None
                        and d["wall_time_s"] >= timeout_sec * 0.9]

    # Startup failures: incomplete runs that ran < 30s (benchmark duration is 30s)
    startup_failures = [d for d in incomplete
                        if d["wall_time_s"] is not None
                        and d["wall_time_s"] < 30]

    # Per-protocol max wall time (completed only)
    proto_max = defaultdict(float)
    for d in completed:
        if d["wall_time_s"] is not None:
            key = d["protocol"]
            proto_max[key] = max(proto_max[key], d["wall_time_s"])

    headroom_pct = ((timeout_sec - max_wt) / timeout_sec * 100) if max_wt > 0 else 100.0

    return {
        "total_runs": len(durations),
        "completed_runs": len(completed),
        "incomplete_runs": len(incomplete),
        "max_completed_wall_time_s": round(max_wt, 1),
        "timeout_sec": timeout_sec,
        "headroom_pct": round(headroom_pct, 1),
        "at_risk_runs": len(at_risk),
        "genuine_timeouts": len(genuine_timeouts),
        "startup_failures": len(startup_failures),
        "per_protocol_max_wall_time": {k: round(v, 1) for k, v in sorted(proto_max.items())},
        "recommendation": _make_recommendation(max_wt, timeout_sec, len(genuine_timeouts)),
    }


def _make_recommendation(max_wall_time, timeout_sec, n_genuine_timeouts):
    """Generate a human-readable recommendation."""
    if n_genuine_timeouts > 0:
        return (f"INCREASE TIMEOUT: {n_genuine_timeouts} run(s) appear to have been "
                f"killed by the {timeout_sec}s timeout. Consider increasing to "
                f"{int(max_wall_time * 2.5)}s.")
    headroom = timeout_sec - max_wall_time
    if headroom < 30:
        return (f"BORDERLINE: max wall time {max_wall_time:.0f}s leaves only "
                f"{headroom:.0f}s headroom. Consider increasing timeout.")
    return (f"SUFFICIENT: max completed wall time {max_wall_time:.0f}s vs "
            f"{timeout_sec}s timeout ({headroom:.0f}s headroom). "
            f"No evidence of timeout-induced failures.")


def build_audit_report(durations, timeout_sec):
    """Build full audit report."""
    classification = classify_timeout_risk(durations, timeout_sec)

    # Incomplete run details (for debugging)
    incomplete_details = []
    for d in sorted(
        [x for x in durations if not x["completed"]],
        key=lambda x: (x["protocol"], x["concurrency"]),
    ):
        incomplete_details.append({
            "protocol": d["protocol"],
            "concurrency": d["concurrency"],
            "mode": d["mode"],
            "server": d["server"],
            "wall_time_s": round(d["wall_time_s"], 1) if d["wall_time_s"] is not None else None,
            "file_size": d["file_size"],
            "has_csv_dump": d["has_csv_dump"],
            "likely_cause": _likely_cause(d, timeout_sec),
        })

    return {
        "timeout_sec": timeout_sec,
        "classification": classification,
        "incomplete_run_details": incomplete_details,
    }


def _likely_cause(run, timeout_sec):
    """Guess the likely cause of an incomplete run."""
    wt = run.get("wall_time_s")
    if wt is None:
        return "unknown"
    if wt >= timeout_sec * 0.9:
        return "genuine_timeout"
    if wt < 10:
        return "startup_failure"
    if wt < 30:
        return "early_crash"
    return "mid_run_failure"


def export_report(report, output_path):
    """Write audit report as JSON."""
    parent = os.path.dirname(output_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(report, f, indent=2)
    print(f"Saved: {output_path}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    result_dir = sys.argv[1]
    if not os.path.isdir(result_dir):
        print(f"Error: {result_dir} is not a directory")
        sys.exit(1)

    timeout_sec = DEFAULT_TIMEOUT
    if "--timeout" in sys.argv:
        idx = sys.argv.index("--timeout")
        timeout_sec = int(sys.argv[idx + 1])

    print(f"Scanning {result_dir} for .res files...")
    durations = collect_durations(result_dir)
    print(f"Found {len(durations)} run files")

    report = build_audit_report(durations, timeout_sec)

    output_path = os.path.join(result_dir, "timeout_audit.json")
    export_report(report, output_path)

    # Print summary
    c = report["classification"]
    print(f"\nTimeout Audit Summary (TIMEOUT_SEC={timeout_sec})")
    print(f"  Total runs:          {c['total_runs']}")
    print(f"  Completed:           {c['completed_runs']}")
    print(f"  Incomplete:          {c['incomplete_runs']}")
    print(f"  Max wall time:       {c['max_completed_wall_time_s']}s")
    print(f"  Headroom:            {c['headroom_pct']}%")
    print(f"  Genuine timeouts:    {c['genuine_timeouts']}")
    print(f"  Startup failures:    {c['startup_failures']}")
    print(f"  At-risk (>80%):      {c['at_risk_runs']}")
    print(f"\n  Per-protocol max wall time:")
    for proto, wt in c["per_protocol_max_wall_time"].items():
        print(f"    {proto:<25s} {wt:.0f}s")
    print(f"\n  Recommendation: {c['recommendation']}")


if __name__ == "__main__":
    main()
