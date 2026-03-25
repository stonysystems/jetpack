#!/usr/bin/env python3
"""
Generate a MongoDB companion figure with appropriate y-axis range.

The main throughput-latency figure caps y-axis at 200ms, which hides
MongoDB entirely (original-path p50 ~10,000ms).  This script produces
a dedicated MongoDB figure using All-efficient-attempts p50
(the correct metric that combines both original-path and fast-path).

Outputs:
  - <result_dir>/figs/<site_tag>_mongodb_companion.pdf
  - <result_dir>/tables/mongodb_companion.csv

Usage:
    python3 scripts/generate_mongodb_companion_figure.py <result_dir>
"""

import os
import re
import csv
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from mongodb_triage import parse_res_metrics, collect_mongodb_data, aggregate_servers


# Mode configs: (label, protocol_prefix, mode_str, color, marker, linestyle)
MODE_CONFIGS = [
    ("Original",  "none_mongodb", "0",   "#437c17",  "^",  "-"),
    ("0%",        "rule_mongodb", "0",   "black",    "x",  ":"),
    ("Adaptive",  "rule_mongodb", "101", "#B22222",  "o",  "-."),
    ("100%",      "rule_mongodb", "100", "orange",   "*",  "--"),
]


def build_mongodb_plot_data(aggregated_data):
    """Build structured rows for the MongoDB companion figure.

    Uses All-efficient-attempts p50 as the latency metric.

    Returns list of dicts:
      [{mode_label, concurrency, throughput, eff_p50, orig_p50, fp_p50}, ...]
    """
    rows = []
    for mode_label, proto_prefix, mode_str, *_ in MODE_CONFIGS:
        points = {k: v for k, v in aggregated_data.items()
                  if k[0] == proto_prefix and k[2] == mode_str and v is not None}
        for (proto, conc, mode), agg in sorted(points.items()):
            conc_num = int(conc.split('_')[1])
            tp = agg.get('total_throughput')
            eff_p50 = agg.get('eff_avg_p50')
            if tp is None:
                continue
            rows.append({
                "mode_label": mode_label,
                "protocol": proto,
                "mode_str": mode_str,
                "concurrency": conc_num,
                "throughput": tp,
                "eff_p50": eff_p50,
                "orig_p50": agg.get('orig_avg_p50'),
                "fp_p50": agg.get('fp_avg_p50'),
                "avg_cpu": agg.get('avg_cpu'),
            })
    return rows


def export_csv(rows, csv_path):
    """Export MongoDB companion data to CSV."""
    os.makedirs(os.path.dirname(csv_path), exist_ok=True)
    sorted_rows = sorted(rows, key=lambda r: (r["mode_label"], r["concurrency"]))
    with open(csv_path, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["mode", "concurrency", "throughput_txn_s",
                         "eff_p50_ms", "orig_p50_ms", "fp_p50_ms", "avg_cpu_pct"])
        for r in sorted_rows:
            writer.writerow([
                r["mode_label"],
                r["concurrency"],
                f"{r['throughput']:.1f}",
                f"{r['eff_p50']:.2f}" if r.get("eff_p50") and r["eff_p50"] > 0 else "",
                f"{r['orig_p50']:.2f}" if r.get("orig_p50") and r["orig_p50"] > 0 else "",
                f"{r['fp_p50']:.2f}" if r.get("fp_p50") and r["fp_p50"] > 0 else "",
                f"{r['avg_cpu']:.2f}" if r.get("avg_cpu") is not None else "",
            ])
    print(f"Saved: {csv_path}")


def generate_figure(rows, pdf_path):
    """Generate two-panel MongoDB companion figure.

    Left panel:  concurrency vs throughput (txn/s)
    Right panel: concurrency vs All-efficient-attempts p50 (ms), log scale
    """
    os.makedirs(os.path.dirname(pdf_path), exist_ok=True)

    fig, (ax_tp, ax_lat) = plt.subplots(1, 2, figsize=(12, 5))

    for mode_label, proto_prefix, mode_str, color, marker, ls in MODE_CONFIGS:
        mode_rows = sorted(
            [r for r in rows if r["mode_label"] == mode_label],
            key=lambda r: r["concurrency"])
        if not mode_rows:
            continue
        xs = [r["concurrency"] for r in mode_rows]

        # Throughput panel
        ys_tp = [r["throughput"] for r in mode_rows]
        ax_tp.plot(xs, ys_tp, label=mode_label, color=color,
                   marker=marker, linestyle=ls, linewidth=1.5, ms=6)

        # Latency panel — only plot points with valid eff_p50
        valid = [(r["concurrency"], r["eff_p50"]) for r in mode_rows
                 if r.get("eff_p50") and r["eff_p50"] > 0]
        if valid:
            xs_lat, ys_lat = zip(*valid)
            ax_lat.plot(xs_lat, ys_lat, label=mode_label, color=color,
                        marker=marker, linestyle=ls, linewidth=1.5, ms=6)

    ax_tp.set_title("MongoDB: Throughput vs Concurrency", fontsize=12)
    ax_tp.set_xlabel("Concurrent Clients", fontsize=11)
    ax_tp.set_ylabel("Throughput (txn/s)", fontsize=11)
    ax_tp.grid(True, linestyle='--', alpha=0.5)
    ax_tp.legend(fontsize=9)

    ax_lat.set_title("MongoDB: Latency vs Concurrency\n(All-efficient-attempts p50)",
                     fontsize=12)
    ax_lat.set_xlabel("Concurrent Clients", fontsize=11)
    ax_lat.set_ylabel("p50 Latency (ms)", fontsize=11)
    ax_lat.set_yscale("log")
    ax_lat.grid(True, linestyle='--', alpha=0.5, which='both')
    ax_lat.legend(fontsize=9)

    plt.tight_layout()
    fig.savefig(pdf_path, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved: {pdf_path}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    result_dir = sys.argv[1]
    if not os.path.isdir(result_dir):
        print(f"Error: {result_dir} is not a directory")
        sys.exit(1)

    site_tag = "30c1s5r5p-zoo"

    print(f"Scanning {result_dir} for MongoDB data...")
    raw_data = collect_mongodb_data(result_dir, site=site_tag)

    if not raw_data:
        print("No MongoDB data found.")
        sys.exit(1)

    # Aggregate per-server data
    aggregated = {}
    for key, server_data in raw_data.items():
        agg = aggregate_servers(server_data)
        if agg is not None:
            aggregated[key] = agg

    print(f"Found {len(aggregated)} complete MongoDB experiment points")

    rows = build_mongodb_plot_data(aggregated)
    print(f"Built {len(rows)} plot data points")

    # Export CSV
    csv_path = os.path.join(result_dir, "tables", "mongodb_companion.csv")
    export_csv(rows, csv_path)

    # Generate figure
    pdf_path = os.path.join(result_dir, "figs", f"{site_tag}_mongodb_companion.pdf")
    generate_figure(rows, pdf_path)

    # Print summary
    print(f"\n{'Mode':<12} {'Conc':<16} {'Throughput':>10} {'Eff p50':>10} "
          f"{'Orig p50':>10} {'FP p50':>10}")
    print("-" * 75)
    for r in sorted(rows, key=lambda r: (r["mode_label"], r["concurrency"])):
        tp = f"{r['throughput']:.0f}"
        ep = f"{r['eff_p50']:.1f}" if r.get("eff_p50") and r["eff_p50"] > 0 else "N/A"
        op = f"{r['orig_p50']:.0f}" if r.get("orig_p50") and r["orig_p50"] > 0 else "N/A"
        fp = f"{r['fp_p50']:.1f}" if r.get("fp_p50") and r["fp_p50"] > 0 else "N/A"
        print(f"{r['mode_label']:<12} concurrent_{r['concurrency']:<10} "
              f"{tp:>10} {ep:>10} {op:>10} {fp:>10}")


if __name__ == "__main__":
    main()
