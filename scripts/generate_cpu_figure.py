#!/usr/bin/env python3
"""
Generate a concurrency-vs-CPU line chart from experiment 0 results.

For each protocol, plots one panel with four mode lines:
  Original (mode=0, none_*), 0% (mode=0, rule_*),
  Adaptive (mode=101, rule_*), 100% (mode=100, rule_*).

Outputs:
  - <result_dir>/figs/<site_tag>_cpu_vs_conc.pdf
  - <result_dir>/tables/cpu_vs_conc.csv

Usage:
    python3 scripts/generate_cpu_figure.py <result_dir>
"""

import os
import re
import csv
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


MAX_RES_FILE_SIZE = 1_000_000


def parse_cpu_median(filepath):
    """Extract 'server median' CPU usage (%) from a .res file."""
    try:
        if os.path.getsize(filepath) > MAX_RES_FILE_SIZE:
            return None
        with open(filepath, 'r') as f:
            for line in f:
                m = re.search(r'server median\s*:\s*([\d.]+)', line)
                if m:
                    val = float(m.group(1))
                    return val if val >= 0 else None
    except (FileNotFoundError, IOError):
        pass
    return None


def collect_cpu_data(result_dir, site="30c1s5r5p-zoo", servers=None):
    """Scan .res files and compute average CPU usage per
    (protocol, concurrent, mode) tuple.

    Returns:
        dict: {protocol: {concurrent: {mode: avg_cpu}}}
    """
    if servers is None:
        servers = [f"zoo{i}" for i in range(5)]

    pattern = re.compile(
        r'^(.+?)-' +
        re.escape(site) + r'-' +
        r'(rw_\d+)-' +
        r'(concurrent_\d+)-' +
        r'(\d+)-' +
        r'(YCSB_[A-Z])-' +
        r'(.+)\.res$'
    )

    parts = defaultdict(dict)

    for fname in os.listdir(result_dir):
        m = pattern.match(fname)
        if not m:
            continue
        protocol, workload, concurrent, mode, ycsb, server = m.groups()
        if server not in servers:
            continue

        filepath = os.path.join(result_dir, fname)
        cpu = parse_cpu_median(filepath)
        if cpu is None:
            continue

        key = (protocol, concurrent, mode)
        parts[key][server] = cpu

    result = defaultdict(lambda: defaultdict(dict))
    for (protocol, concurrent, mode), server_cpus in parts.items():
        if len(server_cpus) < len(servers):
            continue
        avg_cpu = sum(server_cpus.values()) / len(server_cpus)
        result[protocol][concurrent][mode] = avg_cpu

    return result


# Protocol families: (display_name, vanilla_protocol, jetpack_protocol)
PROTOCOL_FAMILIES = [
    ("Raft",      "none_raft",      "rule_raft"),
    ("Copilot",   "none_copilot",   "rule_copilot"),
    ("Mencius",   "none_mencius",   "rule_mencius"),
    ("MongoDB",   "none_mongodb",   "rule_mongodb"),
    ("etcd",      "none_etcd",      "rule_etcd"),
    ("ZooKeeper", "none_zookeeper", "rule_zookeeper"),
]

# Mode configs: (label, mode_str, use_jetpack, color, marker, linestyle)
MODE_CONFIGS = [
    ("Original",  "0",   False, "#437c17",  "^",  "-"),
    ("0%",        "0",   True,  "black",    "x",  ":"),
    ("Adaptive",  "101", True,  "#B22222",  "o",  "-."),
    ("100%",      "100", True,  "orange",   "*",  "--"),
]


def build_plot_data(cpu_data):
    """Build structured data for plotting and CSV export.

    Returns list of dicts:
      [{protocol, display_name, mode_label, concurrency, avg_cpu}, ...]
    """
    rows = []
    for display_name, vanilla, jetpack in PROTOCOL_FAMILIES:
        for mode_label, mode_str, use_jetpack, *_ in MODE_CONFIGS:
            proto = jetpack if use_jetpack else vanilla
            proto_data = cpu_data.get(proto, {})
            for conc, mode_map in proto_data.items():
                cpu_val = mode_map.get(mode_str)
                if cpu_val is not None:
                    conc_num = int(conc.split('_')[1])
                    rows.append({
                        "protocol": display_name,
                        "vanilla_key": vanilla,
                        "jetpack_key": jetpack,
                        "mode_label": mode_label,
                        "mode_str": mode_str,
                        "concurrency": conc_num,
                        "conc_key": conc,
                        "avg_cpu": cpu_val,
                    })
    return rows


def export_csv(rows, csv_path):
    """Export plot data to CSV."""
    os.makedirs(os.path.dirname(csv_path), exist_ok=True)
    sorted_rows = sorted(rows, key=lambda r: (r["protocol"], r["mode_label"],
                                                r["concurrency"]))
    with open(csv_path, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["protocol", "mode", "concurrency", "avg_cpu_pct"])
        for r in sorted_rows:
            writer.writerow([r["protocol"], r["mode_label"],
                             r["concurrency"], f"{r['avg_cpu']:.2f}"])
    print(f"Saved: {csv_path}")


def generate_figure(rows, pdf_path):
    """Generate multi-panel concurrency-vs-CPU line chart."""
    os.makedirs(os.path.dirname(pdf_path), exist_ok=True)

    n_proto = len(PROTOCOL_FAMILIES)
    fig, axes = plt.subplots(1, n_proto, figsize=(5 * n_proto, 4), sharey=True)
    if n_proto == 1:
        axes = [axes]

    line_width = 1.5
    marker_size = 6
    title_font = 12
    label_font = 11
    legend_font = 9

    for col, (display_name, vanilla, jetpack) in enumerate(PROTOCOL_FAMILIES):
        ax = axes[col]
        ax.set_title(display_name, fontsize=title_font)

        for mode_label, mode_str, use_jetpack, color, marker, ls in MODE_CONFIGS:
            proto = jetpack if use_jetpack else vanilla
            # Filter rows for this protocol+mode
            mode_rows = [r for r in rows
                         if r["protocol"] == display_name
                         and r["mode_label"] == mode_label]
            if not mode_rows:
                continue
            mode_rows.sort(key=lambda r: r["concurrency"])
            xs = [r["concurrency"] for r in mode_rows]
            ys = [r["avg_cpu"] for r in mode_rows]
            ax.plot(xs, ys, label=mode_label, color=color,
                    marker=marker, linestyle=ls,
                    linewidth=line_width, ms=marker_size)

        ax.set_xlabel("Concurrent Clients", fontsize=label_font)
        ax.set_ylim(0, 100)
        ax.grid(True, linestyle='--', alpha=0.5)
        if col == 0:
            ax.set_ylabel("CPU Usage (%)", fontsize=label_font)
            ax.legend(fontsize=legend_font)

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

    # Derive site tag from directory name
    site_tag = "30c1s5r5p-zoo"

    print(f"Scanning {result_dir} for CPU data...")
    cpu_data = collect_cpu_data(result_dir, site=site_tag)

    if not cpu_data:
        print("No CPU data found.")
        sys.exit(1)

    rows = build_plot_data(cpu_data)
    print(f"Collected {len(rows)} data points across "
          f"{len(set(r['protocol'] for r in rows))} protocols")

    # Export CSV
    csv_path = os.path.join(result_dir, "tables", "cpu_vs_conc.csv")
    export_csv(rows, csv_path)

    # Generate figure
    figs_dir = os.path.join(result_dir, "figs")
    pdf_path = os.path.join(figs_dir, f"{site_tag}_cpu_vs_conc.pdf")
    generate_figure(rows, pdf_path)


if __name__ == "__main__":
    main()
