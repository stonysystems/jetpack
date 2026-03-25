#!/usr/bin/env python3
"""
Analyze Mencius spot-check results to verify adaptive controller behavior.

Compares throughput and path counters across modes (0, 100, 101) for
Mencius at the concurrency range where the fast path was previously broken
(concurrent_18 through concurrent_60).

Also checks the new [CPU-MENC] log format for correct controller logging.

Usage:
    python3 scripts/mencius_spot_check_analysis.py <result_dir>
"""

import json
import os
import re
import sys
from collections import defaultdict

MID_THROUGHPUT_RE = re.compile(r"Mid throughput is ([\d.]+)")
FP_STATS_RE = re.compile(
    r"All-fast-path-attempts\s+statistics\s+count\s+(\d+)"
)
ORIG_STATS_RE = re.compile(
    r"All-original-path-attempts\s+statistics\s+count\s+(\d+)"
)
EFF_STATS_RE = re.compile(
    r"All-efficient-attempts\s+statistics\s+count\s+(\d+)"
)
# New periodic log format
CPU_MENC_NEW_RE = re.compile(
    r"\[CPU-MENC\] avg_all=([\d.]+) avg_leaders=([\d.]+) max_leader=([\d.]+) "
    r"threshold=([\d.-]+) rand=([\d.]+) cpu_disabled=(\d) go_fp=(\d) fp_cnt=(\d+)"
)
# Old format
CPU_MENC_OLD_RE = re.compile(
    r"\[CPU-MENC\] (?:Disabling|Let go) fastpath due to leader CPU ([\d.]+)"
)

DEFAULT_SERVERS = [f"zoo{i}" for i in range(5)]
SPOT_CHECK_CONCS = [18, 20, 25, 30, 40, 60]

_READ_TAIL_BYTES = 128 * 1024


def parse_res_file(res_path):
    """Parse a Mencius .res file for key metrics."""
    result = {
        "throughput": None,
        "fp_count": None,
        "orig_count": None,
        "eff_count": None,
        "cpu_log_format": "none",
        "cpu_log_count": 0,
        "sample_cpu_values": [],
    }

    if not os.path.isfile(res_path):
        return result

    file_size = os.path.getsize(res_path)
    if file_size == 0:
        return result

    with open(res_path, "rb") as f:
        if file_size > 2 * 1024 * 1024:
            f.seek(-2 * 1024 * 1024, 2)
        content = f.read().decode("utf-8", errors="replace")

    tp_match = MID_THROUGHPUT_RE.search(content)
    if tp_match:
        result["throughput"] = float(tp_match.group(1))

    fp_match = FP_STATS_RE.search(content)
    if fp_match:
        result["fp_count"] = int(fp_match.group(1))

    orig_match = ORIG_STATS_RE.search(content)
    if orig_match:
        result["orig_count"] = int(orig_match.group(1))

    eff_match = EFF_STATS_RE.search(content)
    if eff_match:
        result["eff_count"] = int(eff_match.group(1))

    # Check for new CPU log format
    new_matches = CPU_MENC_NEW_RE.findall(content)
    if new_matches:
        result["cpu_log_format"] = "new"
        result["cpu_log_count"] = len(new_matches)
        result["sample_cpu_values"] = [
            {"avg_leaders": float(m[1]), "go_fp": int(m[6]), "fp_cnt": int(m[7])}
            for m in new_matches[:10]
        ]
    else:
        old_matches = CPU_MENC_OLD_RE.findall(content)
        if old_matches:
            result["cpu_log_format"] = "old"
            result["cpu_log_count"] = len(old_matches)

    return result


def collect_spot_check_data(result_dir, concs=None, servers=None):
    """Collect data for Mencius spot-check concurrency points.

    Returns: {(protocol, conc, mode): {server: metrics}}
    """
    if concs is None:
        concs = SPOT_CHECK_CONCS
    if servers is None:
        servers = DEFAULT_SERVERS

    data = defaultdict(dict)
    for fname in sorted(os.listdir(result_dir)):
        # Match mencius files at spot-check concurrencies
        for proto_prefix in ("none_mencius", "rule_mencius"):
            for conc in concs:
                for mode in ("0", "100", "101"):
                    for server in servers:
                        expected = (f"{proto_prefix}-30c1s5r5p-zoo-rw_1000000-"
                                    f"concurrent_{conc}-{mode}-YCSB_A-{server}.res")
                        if fname == expected:
                            path = os.path.join(result_dir, fname)
                            metrics = parse_res_file(path)
                            data[(proto_prefix, conc, mode)][server] = metrics
    return data


def build_comparison_table(data):
    """Build comparison table of throughput and path counts across modes."""
    rows = []
    for (proto, conc, mode), server_data in sorted(data.items()):
        tps = [s["throughput"] for s in server_data.values() if s["throughput"] is not None]
        fps = [s["fp_count"] for s in server_data.values() if s["fp_count"] is not None]
        origs = [s["orig_count"] for s in server_data.values() if s["orig_count"] is not None]
        effs = [s["eff_count"] for s in server_data.values() if s["eff_count"] is not None]

        # CPU log format check (for adaptive mode only)
        cpu_formats = [s["cpu_log_format"] for s in server_data.values()]
        cpu_counts = [s["cpu_log_count"] for s in server_data.values()]

        rows.append({
            "protocol": proto,
            "concurrency": conc,
            "mode": mode,
            "n_servers": len(server_data),
            "avg_throughput": sum(tps) / len(tps) if tps else None,
            "total_throughput": sum(tps) if tps else None,
            "total_fp_count": sum(fps) if fps else None,
            "total_orig_count": sum(origs) if origs else None,
            "total_eff_count": sum(effs) if effs else None,
            "cpu_log_format": cpu_formats[0] if cpu_formats else "none",
            "total_cpu_logs": sum(cpu_counts),
        })
    return rows


def assess_sanity(rows):
    """Assess whether adaptive mode throughput and path counters are sane.

    Returns list of (severity, message) tuples.
    """
    findings = []

    for conc in SPOT_CHECK_CONCS:
        # Get rows for this concurrency
        none_0 = [r for r in rows if r["protocol"] == "none_mencius"
                   and r["concurrency"] == conc and r["mode"] == "0"]
        rule_0 = [r for r in rows if r["protocol"] == "rule_mencius"
                   and r["concurrency"] == conc and r["mode"] == "0"]
        rule_100 = [r for r in rows if r["protocol"] == "rule_mencius"
                     and r["concurrency"] == conc and r["mode"] == "100"]
        rule_101 = [r for r in rows if r["protocol"] == "rule_mencius"
                     and r["concurrency"] == conc and r["mode"] == "101"]

        baseline_tp = none_0[0]["total_throughput"] if none_0 and none_0[0]["total_throughput"] else None

        # Check rule_100 (fast path)
        if rule_100 and rule_100[0]["total_throughput"] is not None:
            tp_100 = rule_100[0]["total_throughput"]
            if baseline_tp and tp_100 < baseline_tp * 0.1:
                findings.append(("WARN", f"conc_{conc}: mode=100 throughput {tp_100:.0f} "
                                 f"is <10% of baseline {baseline_tp:.0f} — fast path broken"))
            elif baseline_tp and tp_100 < baseline_tp * 0.5:
                findings.append(("INFO", f"conc_{conc}: mode=100 throughput {tp_100:.0f} "
                                 f"is <50% of baseline {baseline_tp:.0f} — degraded"))

        # Check rule_101 (adaptive)
        if rule_101 and rule_101[0]["total_throughput"] is not None:
            tp_101 = rule_101[0]["total_throughput"]
            if baseline_tp and tp_101 < baseline_tp * 0.1:
                findings.append(("WARN", f"conc_{conc}: mode=101 (adaptive) throughput "
                                 f"{tp_101:.0f} is <10% of baseline {baseline_tp:.0f}"))
            elif baseline_tp and tp_101 > baseline_tp * 0.5:
                findings.append(("OK", f"conc_{conc}: mode=101 throughput {tp_101:.0f} "
                                 f"is >50% of baseline {baseline_tp:.0f}"))

            # Check CPU log format
            if rule_101[0]["cpu_log_format"] == "new":
                findings.append(("OK", f"conc_{conc}: mode=101 uses new [CPU-MENC] format "
                                 f"({rule_101[0]['total_cpu_logs']} log lines)"))
            elif rule_101[0]["cpu_log_format"] == "old":
                findings.append(("WARN", f"conc_{conc}: mode=101 still uses OLD [CPU-MENC] format"))
            else:
                findings.append(("INFO", f"conc_{conc}: mode=101 no [CPU-MENC] log lines found"))

    return findings


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

    print(f"Analyzing Mencius spot-check results in {result_dir}...")
    data = collect_spot_check_data(result_dir)
    print(f"Found {len(data)} (protocol, conc, mode) combinations")

    rows = build_comparison_table(data)
    findings = assess_sanity(rows)

    report = {
        "comparison_table": rows,
        "findings": [{"severity": s, "message": m} for s, m in findings],
    }

    output_path = os.path.join(result_dir, "mencius_spot_check_analysis.json")
    export_report(report, output_path)

    # Print table
    print(f"\n{'Protocol':<18s} {'Conc':>6s} {'Mode':>4s} {'Srvs':>4s} "
          f"{'TotalTP':>10s} {'FP#':>8s} {'Orig#':>8s} {'CPUfmt':>8s}")
    print("-" * 80)
    for r in rows:
        tp = f"{r['total_throughput']:.0f}" if r["total_throughput"] else "N/A"
        fp = f"{r['total_fp_count']}" if r["total_fp_count"] is not None else "N/A"
        orig = f"{r['total_orig_count']}" if r["total_orig_count"] is not None else "N/A"
        print(f"{r['protocol']:<18s} {r['concurrency']:6d} {r['mode']:>4s} "
              f"{r['n_servers']:4d} {tp:>10s} {fp:>8s} {orig:>8s} "
              f"{r['cpu_log_format']:>8s}")

    print(f"\nFindings:")
    for s, m in findings:
        marker = "✓" if s == "OK" else ("⚠" if s == "WARN" else "ℹ")
        print(f"  [{s:4s}] {marker} {m}")


if __name__ == "__main__":
    main()
