#!/usr/bin/env python3
"""
Generate CSV tables from Zoo experiment results.

Exports to <result_dir>/tables/:
  - fixed_conc_table.csv: fixed concurrency selection per protocol
  - experiment0_summary.csv: per-protocol peak throughput and latency summary
  - throughput_vs_conc.csv: throughput at each concurrency level per protocol/mode
  - latency_vs_conc.csv: latency percentiles at each concurrency per protocol/mode

Usage:
    python3 scripts/generate_tables.py <result_dir>
"""

import csv
import json
import os
import re
import sys
from collections import defaultdict

SITE = "30c1s5r5p-zoo"
SERVERS = [f"zoo{i}" for i in range(5)]
MODE_LABELS = {"0": "original", "1": "jetpack_100pct", "100": "jetpack_0pct", "101": "adaptive"}


def parse_res_file(path):
    """Extract throughput and latency from a .res file."""
    metrics = {}
    try:
        with open(path) as f:
            for line in f:
                if "Mid throughput is" in line:
                    m = re.search(r"Mid throughput is ([\d.]+)", line)
                    if m:
                        metrics["throughput"] = float(m.group(1))
                if "All-original-path-attempts" in line and "statistics" in line:
                    m = re.search(
                        r"count\s+(\d+)\s+0pct\s+([\d.-]+)\s+50pct\s+([\d.-]+)\s+"
                        r"90pct\s+([\d.-]+)\s+99pct\s+([\d.-]+)\s+ave\s+([\d.-]+)",
                        line,
                    )
                    if m:
                        metrics["count"] = int(m.group(1))
                        metrics["p50"] = float(m.group(3))
                        metrics["p90"] = float(m.group(4))
                        metrics["p99"] = float(m.group(5))
                        metrics["ave"] = float(m.group(6))
                if "All-fast-path-attempts" in line and "statistics" in line:
                    m = re.search(
                        r"count\s+(\d+)\s+0pct\s+([\d.-]+)\s+50pct\s+([\d.-]+)\s+"
                        r"90pct\s+([\d.-]+)\s+99pct\s+([\d.-]+)\s+ave\s+([\d.-]+)",
                        line,
                    )
                    if m:
                        metrics["fp_count"] = int(m.group(1))
                        metrics["fp_p50"] = float(m.group(3))
                        metrics["fp_p90"] = float(m.group(4))
                        metrics["fp_p99"] = float(m.group(5))
                        metrics["fp_ave"] = float(m.group(6))
    except (OSError, IOError):
        pass
    return metrics


def collect_all_data(result_dir):
    """Collect per-protocol, per-mode, per-concurrency data from .res files.

    Returns dict: {(protocol, workload, mode, conc_key): {server: metrics}}
    """
    raw = defaultdict(dict)
    pattern = re.compile(
        r"^(.+?)-" + re.escape(SITE)
        + r"-(rw_[\d._a-z]+)-concurrent_(\d+)-(\d+)-YCSB_A-(.+)\.res$"
    )
    for fname in os.listdir(result_dir):
        m = pattern.match(fname)
        if not m:
            continue
        protocol, workload, conc_num, mode, server = m.groups()
        conc_key = f"concurrent_{conc_num}"
        path = os.path.join(result_dir, fname)
        metrics = parse_res_file(path)
        if metrics:
            raw[(protocol, workload, mode, conc_key)][server] = metrics
    return raw


def aggregate(raw):
    """Aggregate per-server data into per-experiment rows.

    Returns list of dicts, each with protocol, workload, mode, concurrency,
    total_throughput, avg latencies, server_count.
    """
    rows = []
    for (protocol, workload, mode, conc_key), servers in sorted(raw.items()):
        if len(servers) < len(SERVERS):
            continue
        total_tp = sum(s.get("throughput", 0) for s in servers.values())
        n = len(servers)
        row = {
            "protocol": protocol,
            "workload": workload,
            "mode": mode,
            "mode_label": MODE_LABELS.get(mode, f"mode_{mode}"),
            "concurrency": conc_key,
            "conc_num": int(conc_key.split("_")[1]),
            "server_count": n,
            "total_throughput": round(total_tp, 2),
            "avg_p50": round(sum(s.get("p50", 0) for s in servers.values()) / n, 2),
            "avg_p90": round(sum(s.get("p90", 0) for s in servers.values()) / n, 2),
            "avg_p99": round(sum(s.get("p99", 0) for s in servers.values()) / n, 2),
            "avg_ave": round(sum(s.get("ave", 0) for s in servers.values()) / n, 2),
            "avg_fp_p50": round(sum(s.get("fp_p50", 0) for s in servers.values()) / n, 2),
            "avg_fp_p90": round(sum(s.get("fp_p90", 0) for s in servers.values()) / n, 2),
            "avg_fp_p99": round(sum(s.get("fp_p99", 0) for s in servers.values()) / n, 2),
            "avg_fp_ave": round(sum(s.get("fp_ave", 0) for s in servers.values()) / n, 2),
        }
        rows.append(row)
    return rows


def write_csv(path, fieldnames, rows):
    """Write a CSV file."""
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def generate_fixed_conc_table(tables_dir, result_dir):
    """Export fixed_conc_table.csv from fixed_conc.json."""
    fc_path = os.path.join(os.path.dirname(result_dir), "fixed_conc.json")
    if not os.path.isfile(fc_path):
        return None

    with open(fc_path) as f:
        fc = json.load(f)

    rows = []
    for proto, val in sorted(fc.items()):
        conc = val if isinstance(val, str) else val.get("concurrency", "?")
        rows.append({"protocol": proto, "fixed_concurrency": conc})

    path = os.path.join(tables_dir, "fixed_conc_table.csv")
    write_csv(path, ["protocol", "fixed_concurrency"], rows)
    return path


def generate_experiment0_summary(tables_dir, rows):
    """Export experiment0_summary.csv with peak throughput per protocol/mode."""
    # Filter to rw_1000000 workload only (experiment 0)
    exp0 = [r for r in rows if r["workload"] == "rw_1000000"]
    if not exp0:
        return None

    # Find peak throughput per (protocol, mode)
    peaks = {}
    for r in exp0:
        key = (r["protocol"], r["mode"])
        if key not in peaks or r["total_throughput"] > peaks[key]["total_throughput"]:
            peaks[key] = r

    summary_rows = []
    for (proto, mode), r in sorted(peaks.items()):
        summary_rows.append({
            "protocol": proto,
            "mode": r["mode"],
            "mode_label": r["mode_label"],
            "peak_concurrency": r["concurrency"],
            "peak_throughput": r["total_throughput"],
            "p50_at_peak": r["avg_p50"],
            "p90_at_peak": r["avg_p90"],
            "p99_at_peak": r["avg_p99"],
            "avg_at_peak": r["avg_ave"],
        })

    path = os.path.join(tables_dir, "experiment0_summary.csv")
    fields = ["protocol", "mode", "mode_label", "peak_concurrency",
              "peak_throughput", "p50_at_peak", "p90_at_peak",
              "p99_at_peak", "avg_at_peak"]
    write_csv(path, fields, summary_rows)
    return path


def generate_throughput_vs_conc(tables_dir, rows):
    """Export throughput_vs_conc.csv."""
    exp0 = [r for r in rows if r["workload"] == "rw_1000000"]
    if not exp0:
        return None

    out_rows = []
    for r in sorted(exp0, key=lambda x: (x["protocol"], x["mode"], x["conc_num"])):
        out_rows.append({
            "protocol": r["protocol"],
            "mode": r["mode"],
            "mode_label": r["mode_label"],
            "concurrency": r["conc_num"],
            "throughput": r["total_throughput"],
        })

    path = os.path.join(tables_dir, "throughput_vs_conc.csv")
    write_csv(path, ["protocol", "mode", "mode_label", "concurrency", "throughput"],
              out_rows)
    return path


def generate_latency_vs_conc(tables_dir, rows):
    """Export latency_vs_conc.csv with all latency percentiles."""
    exp0 = [r for r in rows if r["workload"] == "rw_1000000"]
    if not exp0:
        return None

    out_rows = []
    for r in sorted(exp0, key=lambda x: (x["protocol"], x["mode"], x["conc_num"])):
        out_rows.append({
            "protocol": r["protocol"],
            "mode": r["mode"],
            "mode_label": r["mode_label"],
            "concurrency": r["conc_num"],
            "throughput": r["total_throughput"],
            "p50": r["avg_p50"],
            "p90": r["avg_p90"],
            "p99": r["avg_p99"],
            "avg": r["avg_ave"],
            "fp_p50": r["avg_fp_p50"],
            "fp_p90": r["avg_fp_p90"],
            "fp_p99": r["avg_fp_p99"],
            "fp_avg": r["avg_fp_ave"],
        })

    path = os.path.join(tables_dir, "latency_vs_conc.csv")
    fields = ["protocol", "mode", "mode_label", "concurrency", "throughput",
              "p50", "p90", "p99", "avg", "fp_p50", "fp_p90", "fp_p99", "fp_avg"]
    write_csv(path, fields, out_rows)
    return path


def generate_tables(result_dir):
    """Generate all CSV tables from result directory."""
    tables_dir = os.path.join(result_dir, "tables")
    os.makedirs(tables_dir, exist_ok=True)

    raw = collect_all_data(result_dir)
    rows = aggregate(raw)

    generated = []

    path = generate_fixed_conc_table(tables_dir, result_dir)
    if path:
        generated.append(path)

    path = generate_experiment0_summary(tables_dir, rows)
    if path:
        generated.append(path)

    path = generate_throughput_vs_conc(tables_dir, rows)
    if path:
        generated.append(path)

    path = generate_latency_vs_conc(tables_dir, rows)
    if path:
        generated.append(path)

    return generated


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 generate_tables.py <result_dir>")
        sys.exit(1)

    result_dir = sys.argv[1]
    if not os.path.isdir(result_dir):
        print(f"Error: {result_dir} is not a directory")
        sys.exit(1)

    generated = generate_tables(result_dir)
    for path in generated:
        print(f"Generated: {path}")
    if not generated:
        print("No tables generated (no complete experiment data found)")


if __name__ == "__main__":
    main()
