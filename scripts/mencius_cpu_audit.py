#!/usr/bin/env python3
"""
Audit the CPU sampling path used by Mencius adaptive mode.

Examines .res files to verify whether the leader CPU values reported
in [CPU-MENC] log lines are plausible, and whether the adaptive
controller is making sensible decisions.

Root-cause analysis of the "leader CPU 0.00" bug:
  1. Server: SampleCpuUsage() returns last_cpu_usage_ which starts at -1.0
  2. FeedResponse: guards with (cpu_usage >= 0.0), so -1.0 is discarded
  3. AvgCpuLeaders(): returns 0.0 when leader_cpu_samples_ == 0
  4. This 0.0 is appended to cpu_usage_leaders_ distribution
  5. recent_100_ave() returns 0.0 → max_leader_avg stays at 0.0
  6. Decision: (0.0 - 60.0) = -60.0 which is never > rand(0,30)
  7. So fast path is NEVER disabled by the CPU check
  8. But fast path (mode=100) itself collapses at concurrent_18+
  9. So adaptive (mode=101) also collapses — the CPU backoff never fires

Outputs:
  - <result_dir>/mencius_cpu_audit.json

Usage:
    python3 scripts/mencius_cpu_audit.py <result_dir>
"""

import json
import os
import re
import sys
from collections import defaultdict

# Match both old format ("leader CPU 0.00") and new format ("avg_leaders=0.00")
CPU_MENC_OLD_RE = re.compile(
    r"\[CPU-MENC\] (?:Disabling|Let go) fastpath due to leader CPU ([\d.]+)"
)
CPU_MENC_NEW_RE = re.compile(
    r"\[CPU-MENC\] avg_all=([\d.]+) avg_leaders=([\d.]+) max_leader=([\d.]+) "
    r"threshold=([\d.-]+) rand=([\d.]+) cpu_disabled=(\d) go_fp=(\d) fp_cnt=(\d+)"
)
MID_THROUGHPUT_RE = re.compile(r"Mid throughput is ([\d.]+)")
FP_STATS_RE = re.compile(
    r"All-fast-path-attempts\s+statistics\s+count\s+(\d+)"
)
ORIG_STATS_RE = re.compile(
    r"All-original-path-attempts\s+statistics\s+count\s+(\d+)"
)

DEFAULT_SERVERS = [f"zoo{i}" for i in range(5)]

_READ_HEAD_BYTES = 4096
_READ_TAIL_BYTES = 128 * 1024  # need more tail for CPU-MENC lines


def extract_mencius_cpu_data(res_path):
    """Extract CPU and throughput data from a Mencius .res file.

    Returns dict with:
      cpu_values: list of floats from [CPU-MENC] lines
      unique_cpu_values: sorted unique values
      total_cpu_lines: int
      cpu_zero_count: int
      cpu_nonzero_count: int
      throughput: float or None
      fp_count: int or None
      orig_count: int or None
    """
    result = {
        "cpu_values_sample": [],
        "unique_cpu_values": [],
        "total_cpu_lines": 0,
        "cpu_zero_count": 0,
        "cpu_nonzero_count": 0,
        "throughput": None,
        "fp_count": None,
        "orig_count": None,
    }

    if not os.path.isfile(res_path):
        return result

    file_size = os.path.getsize(res_path)
    if file_size == 0:
        return result

    # Read full file for CPU-MENC lines (they can be anywhere)
    # But cap at 2MB to avoid memory issues
    with open(res_path, "rb") as f:
        if file_size > 2 * 1024 * 1024:
            f.seek(-2 * 1024 * 1024, 2)
        content = f.read().decode("utf-8", errors="replace")

    cpu_values = []
    # Match old format: "leader CPU <value>"
    for m in CPU_MENC_OLD_RE.finditer(content):
        cpu_values.append(float(m.group(1)))
    # Match new format: "avg_leaders=<value>"
    for m in CPU_MENC_NEW_RE.finditer(content):
        cpu_values.append(float(m.group(2)))  # group 2 = avg_leaders

    result["total_cpu_lines"] = len(cpu_values)
    result["cpu_zero_count"] = sum(1 for v in cpu_values if v == 0.0)
    result["cpu_nonzero_count"] = sum(1 for v in cpu_values if v != 0.0)
    result["unique_cpu_values"] = sorted(set(cpu_values))
    result["cpu_values_sample"] = cpu_values[:20]  # first 20 for inspection

    # Throughput from tail
    tp_match = MID_THROUGHPUT_RE.search(content[-_READ_TAIL_BYTES:] if len(content) > _READ_TAIL_BYTES else content)
    if tp_match:
        result["throughput"] = float(tp_match.group(1))

    fp_match = FP_STATS_RE.search(content[-_READ_TAIL_BYTES:] if len(content) > _READ_TAIL_BYTES else content)
    if fp_match:
        result["fp_count"] = int(fp_match.group(1))

    orig_match = ORIG_STATS_RE.search(content[-_READ_TAIL_BYTES:] if len(content) > _READ_TAIL_BYTES else content)
    if orig_match:
        result["orig_count"] = int(orig_match.group(1))

    return result


def scan_mencius_runs(result_dir, servers=None):
    """Scan for all Mencius adaptive (mode=101) and comparison runs.

    Returns list of dicts with protocol, concurrency, mode, server,
    plus cpu_data from extract_mencius_cpu_data.
    """
    if servers is None:
        servers = DEFAULT_SERVERS

    file_re = re.compile(
        r"^((?:none|rule)_mencius)-30c1s5r5p-zoo-rw_\d+-"
        r"(concurrent_\d+)-(\d+)-YCSB_[A-Z]-(\w+)\.res$"
    )

    results = []
    for fname in sorted(os.listdir(result_dir)):
        m = file_re.match(fname)
        if not m:
            continue
        protocol, concurrent, mode, server = m.groups()
        if server not in servers:
            continue

        path = os.path.join(result_dir, fname)
        cpu_data = extract_mencius_cpu_data(path)

        results.append({
            "protocol": protocol,
            "concurrency": int(concurrent.split("_")[1]),
            "mode": mode,
            "server": server,
            **cpu_data,
        })

    return results


def build_audit_report(runs):
    """Build comprehensive audit report."""

    # Aggregate by (protocol, concurrency, mode)
    grouped = defaultdict(list)
    for r in runs:
        key = (r["protocol"], r["concurrency"], r["mode"])
        grouped[key].append(r)

    # Mode 101 (adaptive) analysis
    adaptive_runs = {k: v for k, v in grouped.items() if k[2] == "101"}
    mode0_runs = {k: v for k, v in grouped.items() if k[2] == "0"}
    mode100_runs = {k: v for k, v in grouped.items() if k[2] == "100"}

    # CPU always zero?
    total_cpu_lines = sum(r["total_cpu_lines"] for r in runs if r["mode"] == "101")
    zero_cpu_lines = sum(r["cpu_zero_count"] for r in runs if r["mode"] == "101")
    nonzero_cpu_lines = sum(r["cpu_nonzero_count"] for r in runs if r["mode"] == "101")

    # Throughput comparison
    throughput_comparison = []
    for (proto, conc, mode), server_runs in sorted(adaptive_runs.items()):
        tps_101 = [r["throughput"] for r in server_runs if r["throughput"] is not None]
        key_0 = (proto.replace("rule_", "none_"), conc, "0")
        key_100 = (proto, conc, "100")
        tps_orig = [r["throughput"] for r in grouped.get(key_0, []) if r["throughput"] is not None]
        tps_0 = [r["throughput"] for r in mode0_runs.get((proto, conc, "0"), []) if r["throughput"] is not None]
        tps_100 = [r["throughput"] for r in mode100_runs.get(key_100, []) if r["throughput"] is not None]

        throughput_comparison.append({
            "protocol": proto,
            "concurrency": conc,
            "mode_0_avg_tp": sum(tps_0) / len(tps_0) if tps_0 else None,
            "mode_100_avg_tp": sum(tps_100) / len(tps_100) if tps_100 else None,
            "mode_101_avg_tp": sum(tps_101) / len(tps_101) if tps_101 else None,
            "none_mencius_avg_tp": sum(tps_orig) / len(tps_orig) if tps_orig else None,
        })

    # Path attempt counts for adaptive
    path_counts = []
    for (proto, conc, mode), server_runs in sorted(adaptive_runs.items()):
        for r in server_runs:
            if r["fp_count"] is not None or r["orig_count"] is not None:
                path_counts.append({
                    "concurrency": conc,
                    "server": r["server"],
                    "fp_count": r["fp_count"],
                    "orig_count": r["orig_count"],
                    "throughput": r["throughput"],
                })

    # Root cause analysis
    root_cause = {
        "bug": "leader_cpu_always_zero",
        "mechanism": (
            "Server SampleCpuUsage() returns last_cpu_usage_ which starts at -1.0. "
            "FeedResponse guards with (cpu_usage >= 0.0), discarding -1.0. "
            "AvgCpuLeaders() returns 0.0 when leader_cpu_samples_==0. "
            "This 0.0 is appended to cpu_usage_leaders_. "
            "The adaptive decision (max_leader_avg - 60.0 > rand(0,30)) never triggers "
            "because max_leader_avg stays at 0.0."
        ),
        "source_files": {
            "cpu_sampling": "src/deptran/scheduler.cc:62-90",
            "cpu_init": "src/deptran/scheduler.h:396 (last_cpu_usage_{-1.0})",
            "feed_response": "src/deptran/communicator.cc:38-46",
            "avg_leaders_fallback": "src/deptran/communicator.h:103 (returns 0.0 when no samples)",
            "decision_logic": "src/deptran/rule/coordinator.cc:78-94",
            "mencius_is_leader": "src/deptran/mencius/server.h:55-57 (always returns true)",
        },
        "why_no_samples": (
            "The CPU monitor coroutine needs TWO successful /proc/stat reads "
            "(200ms apart) before producing the first valid sample. During this "
            "initialization period, SampleCpuUsage() returns -1.0, which FeedResponse "
            "correctly discards. However, the AvgCpuLeaders() fallback of 0.0 "
            "is then treated as a real measurement."
        ),
        "additional_finding": (
            "Even if CPU sampling were fixed, Mencius fast path (mode=100) itself "
            "collapses to zero throughput at concurrent_18+. The adaptive controller "
            "can't help when the underlying fast path is broken."
        ),
    }

    return {
        "summary": {
            "total_adaptive_cpu_lines": total_cpu_lines,
            "zero_cpu_lines": zero_cpu_lines,
            "nonzero_cpu_lines": nonzero_cpu_lines,
            "pct_zero": round(zero_cpu_lines / total_cpu_lines * 100, 1) if total_cpu_lines > 0 else None,
            "adaptive_runs_analyzed": len(adaptive_runs),
        },
        "root_cause": root_cause,
        "throughput_comparison": throughput_comparison,
        "path_counts_sample": path_counts[:30],
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

    print(f"Scanning {result_dir} for Mencius runs...")
    runs = scan_mencius_runs(result_dir)
    print(f"Found {len(runs)} Mencius .res files")

    report = build_audit_report(runs)

    output_path = os.path.join(result_dir, "mencius_cpu_audit.json")
    export_report(report, output_path)

    s = report["summary"]
    print(f"\nMencius CPU Audit Summary:")
    print(f"  Total adaptive CPU log lines:  {s['total_adaptive_cpu_lines']}")
    print(f"  CPU == 0.00:                   {s['zero_cpu_lines']} ({s['pct_zero']}%)")
    print(f"  CPU != 0.00:                   {s['nonzero_cpu_lines']}")

    print(f"\n  Root cause: {report['root_cause']['bug']}")
    print(f"  {report['root_cause']['mechanism'][:200]}...")

    print(f"\n  Throughput comparison (avg per server):")
    print(f"  {'Conc':>6s}  {'none_0':>8s}  {'rule_0':>8s}  {'rule100':>8s}  {'rule101':>8s}")
    for tc in report["throughput_comparison"]:
        def fmt(v):
            return f"{v:8.1f}" if v is not None else "    N/A"
        print(f"  {tc['concurrency']:6d}  {fmt(tc['none_mencius_avg_tp'])}  "
              f"{fmt(tc['mode_0_avg_tp'])}  {fmt(tc['mode_100_avg_tp'])}  "
              f"{fmt(tc['mode_101_avg_tp'])}")


if __name__ == "__main__":
    main()
