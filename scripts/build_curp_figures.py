#!/usr/bin/env python3
# build_curp_figures.py
#
# Reads the per-set summary CSVs and per-cmd latency CSVs produced by
# run_curp_data_sweep.sh and emits the eight figures used by the paper.
#
# Inputs (all under <result_root>):
#   set_a_throughput_latency/<label>-<workload>-N<N>c500-zoo<i>.csv  (per-cmd)
#   set_b_keyrange/...                                                (per-cmd)
#   set_c_zipf/...                                                    (per-cmd)
#   set_a_summary.csv  set_b_summary.csv  set_c_summary.csv
#   fixed_n_per_protocol.csv
#
# Output: <result_root>/figures/*.png + per-figure data CSVs under
#         <result_root>/figures/data/.
#
# Usage:
#   python3 scripts/build_curp_figures.py <result_root>

import argparse
import csv
import math
import os
import re
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


# Parse a per-cmd CSV from results/recent_csv. Column 7 is End2End-Latency.
PER_CMD_LATENCY_COL = "End2End-Latency"


def read_summary(path):
    rows = []
    with open(path) as f:
        reader = csv.DictReader(f)
        for r in reader:
            rows.append(r)
    return rows


def read_per_cmd_latencies_ms(csv_path):
    """End2End-Latency from a per-cmd csv. Returns a numpy float array (ms)."""
    if not os.path.isfile(csv_path):
        return np.empty(0)
    try:
        with open(csv_path) as f:
            reader = csv.DictReader(f)
            if PER_CMD_LATENCY_COL not in reader.fieldnames:
                return np.empty(0)
            vals = []
            for r in reader:
                v = r.get(PER_CMD_LATENCY_COL, "")
                try:
                    vals.append(float(v))
                except (TypeError, ValueError):
                    continue
            return np.asarray(vals, dtype=float)
    except Exception:
        return np.empty(0)


def per_cmd_csv_for(set_dir, run_label, replica_idx):
    return os.path.join(set_dir, f"{run_label}-zoo{replica_idx+1}.csv")


def collect_per_cmd_for_run(set_dir, run_label, replicas=range(5)):
    arrs = []
    for i in replicas:
        a = read_per_cmd_latencies_ms(per_cmd_csv_for(set_dir, run_label, i))
        if a.size:
            arrs.append(a)
    if not arrs:
        return np.empty(0)
    return np.concatenate(arrs)


def avg_latency_ms_for_run(set_dir, run_label):
    a = collect_per_cmd_for_run(set_dir, run_label)
    return float(np.mean(a)) if a.size else float("nan")


# Color/marker per protocol family for consistency across figures.
PROTO_STYLE = {
    "raft":              ("#1f77b4", "o"),
    "jp-raft-fp0":       ("#1f77b4", "s"),
    "jp-raft-fp100":     ("#1f77b4", "^"),
    "jp-raft-adaptive":  ("#1f77b4", "v"),
    "copilot":              ("#ff7f0e", "o"),
    "jp-copilot-fp0":       ("#ff7f0e", "s"),
    "jp-copilot-fp100":     ("#ff7f0e", "^"),
    "jp-copilot-adaptive":  ("#ff7f0e", "v"),
    "mencius":              ("#2ca02c", "o"),
    "jp-mencius-fp0":       ("#2ca02c", "s"),
    "jp-mencius-fp100":     ("#2ca02c", "^"),
    "jp-mencius-adaptive":  ("#2ca02c", "v"),
    "etcd":              ("#d62728", "o"),
    "jp-etcd-fp0":       ("#d62728", "s"),
    "jp-etcd-fp100":     ("#d62728", "^"),
    "jp-etcd-adaptive":  ("#d62728", "v"),
    "mongodb":              ("#9467bd", "o"),
    "jp-mongodb-fp0":       ("#9467bd", "s"),
    "jp-mongodb-fp100":     ("#9467bd", "^"),
    "jp-mongodb-adaptive":  ("#9467bd", "v"),
    "epaxos":     ("#8c564b", "D"),
    "swiftpaxos": ("#e377c2", "D"),
    "curp":       ("#7f7f7f", "D"),
}


def fnum(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return float("nan")


def workload_to_keyrange(wl):
    # rw_<N>  -> N
    m = re.match(r"rw_(\d+)$", wl)
    if m:
        return int(m.group(1))
    return None


def workload_to_zipf(wl):
    if wl == "rw_1000000":
        return 0.0  # uniform baseline
    m = re.match(r"rw_zipf_([\d.]+)$", wl)
    if m:
        return float(m.group(1))
    return None


def by_protocol(rows):
    groups = defaultdict(list)
    for r in rows:
        groups[r["protocol"]].append(r)
    return groups


def fig_throughput_latency(set_a_rows, out_dir, data_dir):
    groups = by_protocol(set_a_rows)
    fig, ax = plt.subplots(figsize=(8, 5))
    csv_path = os.path.join(data_dir, "fig_throughput_latency.csv")
    with open(csv_path, "w") as out:
        out.write("protocol,N,total_tput,z2_p50_ms\n")
        for proto, rows in groups.items():
            color, marker = PROTO_STYLE.get(proto, ("#000", "o"))
            xs = []
            ys = []
            rows_sorted = sorted(rows, key=lambda r: int(r["N"]))
            for r in rows_sorted:
                tp = fnum(r["total_tput"])
                p50 = fnum(r["z2_p50"])
                if not math.isfinite(tp) or not math.isfinite(p50):
                    continue
                if tp <= 0 or p50 <= 0:
                    continue
                xs.append(tp)
                ys.append(p50)
                out.write(f"{proto},{r['N']},{tp},{p50}\n")
            if xs:
                ax.plot(xs, ys, color=color, marker=marker, linewidth=1.2,
                        markersize=5, label=proto)
    ax.set_xlabel("Total throughput (cmd/s)")
    ax.set_ylabel("zoo2 p50 latency (ms)")
    ax.set_title("Throughput vs latency")
    ax.set_yscale("log")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left", fontsize=7, ncol=2)
    plt.tight_layout()
    plt.savefig(os.path.join(out_dir, "fig_throughput_latency.png"), dpi=140)
    plt.close(fig)


def fig_latency_cdf(set_a_dir, set_a_rows, fixed_n_map, out_dir, data_dir):
    """Latency CDF at the per-protocol fixed-N point (from Set A)."""
    fig, ax = plt.subplots(figsize=(8, 5))
    csv_path = os.path.join(data_dir, "fig_latency_cdf.csv")
    with open(csv_path, "w") as out:
        out.write("protocol,latency_ms,cumulative_fraction\n")
        for proto, rows in by_protocol(set_a_rows).items():
            target_n = fixed_n_map.get(proto)
            if target_n is None:
                continue
            run_label = f"{proto}-rw_1000000-N{target_n}c500"
            arr = collect_per_cmd_for_run(set_a_dir, run_label)
            if arr.size == 0:
                continue
            arr = np.sort(arr)
            ys = np.arange(1, arr.size + 1) / arr.size
            color, marker = PROTO_STYLE.get(proto, ("#000", None))
            # subsample for the CSV (every ~1000th point)
            step = max(1, arr.size // 1000)
            for x, y in zip(arr[::step], ys[::step]):
                out.write(f"{proto},{x},{y}\n")
            ax.plot(arr, ys, color=color, linewidth=1.0, label=proto)
    ax.set_xlabel("End-to-end latency (ms)")
    ax.set_ylabel("Cumulative fraction")
    ax.set_xscale("log")
    ax.set_title("Latency CDF at fixed N (per-protocol ~50% leader CPU)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="lower right", fontsize=7, ncol=2)
    plt.tight_layout()
    plt.savefig(os.path.join(out_dir, "fig_latency_cdf.png"), dpi=140)
    plt.close(fig)


def fig_keyrange_avg_latency(set_b_rows, set_b_dir, out_dir, data_dir):
    fig, ax = plt.subplots(figsize=(8, 5))
    csv_path = os.path.join(data_dir, "fig_keyrange_avg_latency.csv")
    with open(csv_path, "w") as out:
        out.write("protocol,key_range,N,avg_latency_ms\n")
        for proto, rows in by_protocol(set_b_rows).items():
            color, marker = PROTO_STYLE.get(proto, ("#000", "o"))
            data = []
            for r in rows:
                kr = workload_to_keyrange(r["workload"])
                if kr is None:
                    continue
                run_label = f"{proto}-{r['workload']}-N{r['N']}c500"
                avg = avg_latency_ms_for_run(set_b_dir, run_label)
                if not math.isfinite(avg):
                    continue
                data.append((kr, avg))
                out.write(f"{proto},{kr},{r['N']},{avg}\n")
            data.sort()
            if data:
                xs = [d[0] for d in data]
                ys = [d[1] for d in data]
                ax.plot(xs, ys, color=color, marker=marker, linewidth=1.2,
                        markersize=5, label=proto)
    ax.set_xlabel("Key range (number of distinct keys)")
    ax.set_ylabel("Average latency (ms)")
    ax.set_xscale("log")
    ax.set_title("Key range vs average latency (fixed N, ~50% leader CPU)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper right", fontsize=7, ncol=2)
    plt.tight_layout()
    plt.savefig(os.path.join(out_dir, "fig_keyrange_avg_latency.png"), dpi=140)
    plt.close(fig)


def _fig_zipf_metric(set_c_rows, set_c_dir, metric_fn, ylabel, title,
                     out_path, data_path, log_y=False):
    fig, ax = plt.subplots(figsize=(8, 5))
    with open(data_path, "w") as out:
        out.write(f"protocol,zipf,N,{ylabel.replace(' ', '_').lower()}\n")
        for proto, rows in by_protocol(set_c_rows).items():
            color, marker = PROTO_STYLE.get(proto, ("#000", "o"))
            data = []
            for r in rows:
                z = workload_to_zipf(r["workload"])
                if z is None:
                    continue
                run_label = f"{proto}-{r['workload']}-N{r['N']}c500"
                v = metric_fn(r, set_c_dir, run_label)
                if not math.isfinite(v):
                    continue
                data.append((z, v))
                out.write(f"{proto},{z},{r['N']},{v}\n")
            data.sort()
            if data:
                xs = [d[0] for d in data]
                ys = [d[1] for d in data]
                ax.plot(xs, ys, color=color, marker=marker, linewidth=1.2,
                        markersize=5, label=proto)
    ax.set_xlabel("Zipf coefficient")
    ax.set_ylabel(ylabel)
    if log_y:
        ax.set_yscale("log")
    ax.set_title(title)
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left", fontsize=7, ncol=2)
    plt.tight_layout()
    plt.savefig(out_path, dpi=140)
    plt.close(fig)


def fig_zipf_avg_latency(set_c_rows, set_c_dir, out_dir, data_dir):
    _fig_zipf_metric(
        set_c_rows, set_c_dir,
        lambda r, d, lbl: avg_latency_ms_for_run(d, lbl),
        "Average latency (ms)", "Zipf vs avg latency",
        os.path.join(out_dir, "fig_zipf_avg_latency.png"),
        os.path.join(data_dir, "fig_zipf_avg_latency.csv"),
        log_y=True,
    )


def fig_zipf_p90(set_c_rows, set_c_dir, out_dir, data_dir):
    _fig_zipf_metric(
        set_c_rows, set_c_dir,
        lambda r, d, lbl: fnum(r["z2_p90"]),
        "p90 latency (ms)", "Zipf vs p90 latency",
        os.path.join(out_dir, "fig_zipf_p90.png"),
        os.path.join(data_dir, "fig_zipf_p90.csv"),
        log_y=True,
    )


def fig_zipf_p99(set_c_rows, set_c_dir, out_dir, data_dir):
    _fig_zipf_metric(
        set_c_rows, set_c_dir,
        lambda r, d, lbl: fnum(r["z2_p99"]),
        "p99 latency (ms)", "Zipf vs p99 latency",
        os.path.join(out_dir, "fig_zipf_p99.png"),
        os.path.join(data_dir, "fig_zipf_p99.csv"),
        log_y=True,
    )


def fig_zipf_fp_rate(set_c_rows, set_c_dir, out_dir, data_dir):
    _fig_zipf_metric(
        set_c_rows, set_c_dir,
        lambda r, d, lbl: fnum(r["fp_rate"]),
        "Fast-path attempt success rate (%)", "Zipf vs fast-path rate",
        os.path.join(out_dir, "fig_zipf_fp_rate.png"),
        os.path.join(data_dir, "fig_zipf_fp_rate.csv"),
    )


def fig_zipf_success_rate(set_c_rows, set_c_dir, out_dir, data_dir):
    _fig_zipf_metric(
        set_c_rows, set_c_dir,
        lambda r, d, lbl: fnum(r["fp_eff_rate"]),
        "Efficient fast-path success rate (%)", "Zipf vs success rate",
        os.path.join(out_dir, "fig_zipf_success_rate.png"),
        os.path.join(data_dir, "fig_zipf_success_rate.csv"),
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("result_root")
    args = ap.parse_args()

    root = args.result_root
    out_dir = os.path.join(root, "figures")
    data_dir = os.path.join(out_dir, "data")
    os.makedirs(data_dir, exist_ok=True)

    set_a_rows = read_summary(os.path.join(root, "set_a_summary.csv"))
    set_b_rows = read_summary(os.path.join(root, "set_b_summary.csv"))
    set_c_rows = read_summary(os.path.join(root, "set_c_summary.csv"))

    fixed_n_path = os.path.join(root, "fixed_n_per_protocol.csv")
    fixed_n_map = {}
    if os.path.isfile(fixed_n_path):
        with open(fixed_n_path) as f:
            for r in csv.DictReader(f):
                fixed_n_map[r["protocol"]] = r["fixed_N"]

    set_a_dir = os.path.join(root, "set_a_throughput_latency")
    set_b_dir = os.path.join(root, "set_b_keyrange")
    set_c_dir = os.path.join(root, "set_c_zipf")

    print(f"figures -> {out_dir}")
    fig_throughput_latency(set_a_rows, out_dir, data_dir)
    fig_latency_cdf(set_a_dir, set_a_rows, fixed_n_map, out_dir, data_dir)
    fig_keyrange_avg_latency(set_b_rows, set_b_dir, out_dir, data_dir)
    fig_zipf_avg_latency(set_c_rows, set_c_dir, out_dir, data_dir)
    fig_zipf_p90(set_c_rows, set_c_dir, out_dir, data_dir)
    fig_zipf_p99(set_c_rows, set_c_dir, out_dir, data_dir)
    fig_zipf_fp_rate(set_c_rows, set_c_dir, out_dir, data_dir)
    fig_zipf_success_rate(set_c_rows, set_c_dir, out_dir, data_dir)
    print("done.")


if __name__ == "__main__":
    main()
