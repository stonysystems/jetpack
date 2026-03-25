#!/usr/bin/env python3
"""
Audit the post-run cleanup/scp race with CSV dump completion.

Analyzes whether the current run scripts have a race condition between
server CSV dump completion, process cleanup (pkill -9), and file retrieval
(scp).  Cross-references the CSV audit data to quantify the impact.

The race has three independent failure modes:
  1. pkill_before_dump: Server is killed (pkill -9) before CSV dump completes.
     Evidence: .res file has statistics but no "Dumped to" line.
  2. nfs_cache_lag: Server wrote CSV (has "Dumped to" line) but scp ran before
     NFS flushed the write to the file server.  Evidence: "Dumped to" in .res
     but CSV file missing locally (scp_pull_gap in csv_audit).
  3. partial_csv: Server was killed during CSV write.  Evidence: CSV file exists
     but is truncated (fewer lines than expected from the dump message).

This script quantifies each failure mode from existing data.

Outputs:
  - <result_dir>/scp_race_audit.json

Usage:
    python3 scripts/scp_race_audit.py <result_dir>
"""

import json
import os
import re
import sys
from collections import defaultdict

DEFAULT_SERVERS = [f"zoo{i}" for i in range(5)]

DUMP_RE = re.compile(r"Dumped to .+\.csv with (\d+) lines")
STATISTICS_RE = re.compile(r"All-efficient-attempts\s+statistics\s+count\s+(\d+)")
MID_THROUGHPUT_RE = re.compile(r"Mid throughput is ([\d.]+)")
SHUTDOWN_RE = re.compile(r"server_shutdown")

_READ_TAIL_BYTES = 64 * 1024


def _read_tail(filepath, tail_bytes=_READ_TAIL_BYTES):
    """Read the last N bytes of a file."""
    file_size = os.path.getsize(filepath)
    with open(filepath, "rb") as f:
        if file_size > tail_bytes:
            f.seek(-tail_bytes, 2)
        return f.read().decode("utf-8", errors="replace")


def analyze_server_run(res_path, csv_path):
    """Analyze one server's run for race-condition evidence.

    Returns dict with:
      has_res: bool
      has_csv: bool
      has_statistics: bool
      has_dump_line: bool
      dump_lines_expected: int or None
      csv_lines_actual: int or None
      has_shutdown: bool
      has_mid_throughput: bool
      race_mode: str  (none, pkill_before_dump, nfs_cache_lag, partial_csv, other)
      evidence: str
    """
    result = {
        "has_res": os.path.isfile(res_path),
        "has_csv": os.path.isfile(csv_path),
        "has_statistics": False,
        "has_dump_line": False,
        "dump_lines_expected": None,
        "csv_lines_actual": None,
        "has_shutdown": False,
        "has_mid_throughput": False,
        "race_mode": "none",
        "evidence": "",
    }

    if not result["has_res"]:
        result["race_mode"] = "no_res"
        return result

    tail = _read_tail(res_path)

    result["has_statistics"] = bool(STATISTICS_RE.search(tail))
    result["has_mid_throughput"] = bool(MID_THROUGHPUT_RE.search(tail))
    result["has_shutdown"] = bool(SHUTDOWN_RE.search(tail))

    dump_match = DUMP_RE.search(tail)
    if dump_match:
        result["has_dump_line"] = True
        result["dump_lines_expected"] = int(dump_match.group(1))

    # Check CSV file
    if result["has_csv"]:
        try:
            with open(csv_path, "r") as f:
                # Count lines (subtract 1 for header)
                line_count = sum(1 for _ in f) - 1
                result["csv_lines_actual"] = max(0, line_count)
        except OSError:
            result["csv_lines_actual"] = None

    # Classify race mode
    if result["has_csv"] and result["has_dump_line"]:
        # Check for truncation
        if (result["csv_lines_actual"] is not None
                and result["dump_lines_expected"] is not None
                and result["csv_lines_actual"] < result["dump_lines_expected"] * 0.9):
            result["race_mode"] = "partial_csv"
            result["evidence"] = (
                f"expected {result['dump_lines_expected']} lines, "
                f"got {result['csv_lines_actual']}"
            )
        else:
            result["race_mode"] = "none"
        return result

    if result["has_dump_line"] and not result["has_csv"]:
        result["race_mode"] = "nfs_cache_lag"
        result["evidence"] = (
            f"server logged 'Dumped to' ({result['dump_lines_expected']} lines) "
            f"but CSV not found locally"
        )
        return result

    if result["has_statistics"] and not result["has_dump_line"]:
        result["race_mode"] = "pkill_before_dump"
        result["evidence"] = "has statistics but no dump line — likely killed before CSV write"
        return result

    if result["has_mid_throughput"] and not result["has_dump_line"]:
        result["race_mode"] = "pkill_before_dump"
        result["evidence"] = "has Mid throughput but no dump line"
        return result

    return result


def scan_all_runs(result_dir, servers=None):
    """Scan result directory and analyze each server's run for race evidence.

    Returns list of analysis dicts, one per server per prefix.
    """
    if servers is None:
        servers = DEFAULT_SERVERS

    server_pattern = "|".join(re.escape(s) for s in servers)
    res_re = re.compile(rf"^(.+)-({server_pattern})\.res$")

    results = []
    for fname in sorted(os.listdir(result_dir)):
        m = res_re.match(fname)
        if not m:
            continue
        prefix, server = m.groups()
        res_path = os.path.join(result_dir, fname)
        csv_path = os.path.join(result_dir, f"{prefix}-{server}.csv")
        analysis = analyze_server_run(res_path, csv_path)
        analysis["prefix"] = prefix
        analysis["server"] = server
        results.append(analysis)

    return results


def build_race_report(analyses):
    """Build structured report from analyses.

    Returns dict with summary counts and affected prefixes.
    """
    mode_counts = defaultdict(int)
    affected_prefixes = defaultdict(list)

    for a in analyses:
        mode = a["race_mode"]
        mode_counts[mode] += 1
        if mode not in ("none", "no_res"):
            affected_prefixes[mode].append({
                "prefix": a["prefix"],
                "server": a["server"],
                "evidence": a["evidence"],
            })

    total = len(analyses)
    total_with_race = sum(v for k, v in mode_counts.items() if k not in ("none", "no_res"))

    # Script-level analysis: document the race in 10-run_all.sh
    script_analysis = {
        "scripts_affected": ["scripts/10-run_all.sh", "scripts/09-build_and_test_run_wan.sh"],
        "race_description": (
            "After SSH wait returns, the script sends pkill -9 to all servers, "
            "sleeps 1 second, then runs scp to fetch CSV files. Three race windows: "
            "(1) pkill -9 kills server before it finishes CSV dump; "
            "(2) NFS write-behind cache means CSV may not be visible for scp even "
            "after the server closed the file (sleep 1 is insufficient for NFS "
            "attribute cache, which defaults to 3-60 seconds); "
            "(3) Server killed mid-CSV-write produces truncated file."
        ),
        "recommended_fixes": [
            "Add 'sync' call on remote servers after wait and before scp "
            "to flush NFS write-behind cache",
            "Replace pkill -9 with graceful SIGTERM first, with a timeout "
            "before escalating to SIGKILL",
            "Increase sleep between kill and scp to at least 5 seconds, or "
            "add an NFS stat-based wait loop",
            "Add CSV completeness check after scp: verify line count matches "
            "the 'Dumped to' line in .res",
        ],
    }

    return {
        "summary": {
            "total_server_runs": total,
            "clean_runs": mode_counts.get("none", 0),
            "no_res_file": mode_counts.get("no_res", 0),
            "race_affected": total_with_race,
            "by_race_mode": dict(mode_counts),
        },
        "script_analysis": script_analysis,
        "affected_details": {
            mode: entries[:20]  # cap at 20 examples per mode
            for mode, entries in affected_prefixes.items()
        },
        "affected_counts_by_mode": {
            mode: len(entries) for mode, entries in affected_prefixes.items()
        },
    }


def export_report(report, output_path):
    """Write report as JSON."""
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

    print(f"Scanning {result_dir} for race condition evidence...")
    analyses = scan_all_runs(result_dir)
    print(f"Analyzed {len(analyses)} server runs")

    report = build_race_report(analyses)

    output_path = os.path.join(result_dir, "scp_race_audit.json")
    export_report(report, output_path)

    s = report["summary"]
    print(f"\nSCP Race Audit Summary:")
    print(f"  Total server runs:     {s['total_server_runs']}")
    print(f"  Clean (no race):       {s['clean_runs']}")
    print(f"  No .res file:          {s['no_res_file']}")
    print(f"  Race-affected:         {s['race_affected']}")
    print(f"\n  By race mode:")
    for mode, count in sorted(s["by_race_mode"].items(), key=lambda x: -x[1]):
        if mode in ("none", "no_res"):
            continue
        print(f"    {mode:<25s} {count:>5d}")

    print(f"\n  Script analysis:")
    sa = report["script_analysis"]
    print(f"    {sa['race_description']}")
    print(f"\n  Recommended fixes:")
    for fix in sa["recommended_fixes"]:
        print(f"    - {fix}")


if __name__ == "__main__":
    main()
