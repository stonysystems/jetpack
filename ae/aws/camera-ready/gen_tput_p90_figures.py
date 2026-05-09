#!/usr/bin/env python3
"""
Camera-ready throughput-vs-p90-latency figures.

Per folder (passed as --result-dir or auto-discovered), produces in <folder>/figs/:
  * tput_p90_latency_grid.{pdf,png}
        1x5 row: Raft, Copilot, Mencius, MongoDB, etcd. (ZooKeeper dropped.)
        Per panel: {vanilla, adaptive (rule@101), 100% (rule@100)} curves
        (this dataset has no rule@0 line, unlike the OSDI dataset).
  * tput_p90_raft_curp_swiftpaxos_epaxos.{pdf,png}
        Single panel: vanilla Raft, Raft+Jetpack adaptive, CURP, SwiftPaxos, EPaxos.

A data point (proto, pct, conc) is included only if all 10 .csv AND all 10 .res
files exist for that prefix AND every host's .res file parses cleanly with both
"Mid throughput" and "All-efficient-attempts ... 90pct".

Throughput  = sum of "Mid throughput" across the 10 client hosts.
p90 latency = median across the 10 host p90 values (matches the prior
              gen_tput_latency_figure.py convention in these folders).
"""

import argparse
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ------------------------------------------------------------------------
# Parsing
# ------------------------------------------------------------------------
MID_RE  = re.compile(r"Mid throughput is\s+([0-9.]+)")
STAT_RE = re.compile(
    r"All-efficient-attempts\s+statistics\s+count\s+\d+\s+"
    r"0pct\s+([0-9.]+)\s+50pct\s+([0-9.]+)\s+90pct\s+([0-9.]+)\s+"
    r"99pct\s+([0-9.]+)\s+ave\s+([0-9.]+)"
)
ERR_RE  = re.compile(r"generic server error")
DUMP_RE = re.compile(r"Dumped to")
NHOSTS  = 10

# Latency metric -> (regex group index in STAT_RE, axis label, filename slug)
LATENCY_METRICS = {
    "p50": (2, "p50 Latency (ms)", "p50"),
    "p90": (3, "p90 Latency (ms)", "p90"),
    "p99": (4, "p99 Latency (ms)", "p99"),
    "ave": (5, "Average Latency (ms)", "ave"),
}


def parse_res(path):
    """Return (mid_tput, {p50,p90,p99,ave: float}) or None if file unusable."""
    try:
        txt = open(path, errors="replace").read()
    except FileNotFoundError:
        return None
    if ERR_RE.search(txt):
        return None
    if not DUMP_RE.search(txt):
        return None
    m_mid  = MID_RE.search(txt)
    m_stat = STAT_RE.search(txt)
    if not (m_mid and m_stat):
        return None
    lat = {
        "p50": float(m_stat.group(2)),
        "p90": float(m_stat.group(3)),
        "p99": float(m_stat.group(4)),
        "ave": float(m_stat.group(5)),
    }
    return (float(m_mid.group(1)), lat)


# ---- per-(prefix) parse cache keyed by (log_dir, proto, conc, mode) ----
_AGG_CACHE = {}


def aggregate_rows(log_dir, proto, conc, mode):
    """Return [(mid_tput, p90), …] of length 10 (one per host), or None if
    any of the 20 csv/res files is missing or any host fails to parse."""
    key = (log_dir, proto, conc, mode)
    if key in _AGG_CACHE:
        return _AGG_CACHE[key]
    rows = []
    for i in range(NHOSTS):
        prefix = f"{proto}-60c1s5r10p-rw_1000000-concurrent_{conc}-{mode}-YCSB_A-server{i}"
        csv_p = os.path.join(log_dir, prefix + ".csv")
        res_p = os.path.join(log_dir, prefix + ".res")
        if not (os.path.isfile(csv_p) and os.path.isfile(res_p)):
            _AGG_CACHE[key] = None
            return None
        v = parse_res(res_p)
        if v is None:
            _AGG_CACHE[key] = None
            return None
        rows.append(v)
    _AGG_CACHE[key] = rows
    return rows


def aggregate(log_dir, proto, conc, mode, metric):
    """Sum-throughput + median-of-host-`metric` over 10 hosts, or None."""
    rows = aggregate_rows(log_dir, proto, conc, mode)
    if rows is None:
        return None
    tput = sum(r[0] for r in rows)
    vals = sorted(r[1][metric] for r in rows)
    med  = 0.5 * (vals[NHOSTS // 2 - 1] + vals[NHOSTS // 2])
    return tput, med


def aggregate_dc(log_dir, proto, conc, mode, dc, metric):
    """One host's throughput + that host's `metric` value, after cluster gate."""
    rows = aggregate_rows(log_dir, proto, conc, mode)
    if rows is None:
        return None
    return rows[dc][0], rows[dc][1][metric]


def collect_concs(log_dir, proto, mode):
    """List all concurrency ints with at least one server file present."""
    pat = re.compile(rf"^{re.escape(proto)}-60c1s5r10p-rw_1000000-concurrent_(\d+)-{mode}-YCSB_A-server\d+\.(csv|res)$")
    concs = set()
    try:
        for name in os.listdir(log_dir):
            m = pat.match(name)
            if m:
                concs.add(int(m.group(1)))
    except FileNotFoundError:
        pass
    return sorted(concs)


# Hand-curated bans of unstable concurrency points. Cleared 2026-05-07 (the
# OSDI list was hiding v2 post-knee points), repopulated 2026-05-08 with v2-
# specific entries identified from the latest sweep (raft saturation tail,
# copilot/mencius outlier cells from bisection runs).
BANNED_CONC = {
    ("none_raft",     0):   {200, 250, 275, 300},
    ("rule_raft",   100):   {225, 275, 300},
    ("rule_raft",   101):   {200, 275, 300},
    ("rule_copilot", 100):  {64},
    ("rule_mencius", 101):  {27},
}

# Latency-outlier filter disabled (2026-05-07) for the same reason: v2
# data is intentionally captured into and beyond the saturation knee, and
# the 1.1× ratio was hiding post-knee tput plateaus that the summary
# table shows. Set BAD_LATENCY_RATIO to e.g. 2.0 if you want a softer
# trim, or back to 1.1 to restore OSDI behaviour.
BAD_LATENCY_RATIO = float("inf")


def filter_latency_outliers(points, ratio=BAD_LATENCY_RATIO):
    """`points` is a list of (conc, throughput, p90) sorted by conc ascending."""
    if not points:
        return []
    kept = []
    n = len(points)
    for i, (c, t, lat) in enumerate(points):
        if i < n - 1:
            later_lats = [p[2] for p in points[i + 1:] if p[2] is not None]
            if later_lats:
                min_later = float(min(later_lats))
                if min_later > 0 and lat > min_later * ratio:
                    continue
        kept.append((c, t, lat))
    return kept


def series_for(log_dir, proto, mode, metric="p90", dc=None):
    """Return list of (conc, throughput, latency_value) for points with full
    files, after applying the OSDI ban list and the latency-outlier filter.

    `metric` ∈ {"p50", "p90", "p99", "ave"}.
    `dc=None` (default) → cluster sum/median over 10 hosts.
    `dc=k` → that single host's mid_throughput and `metric` value (still
             gated on cluster-completeness so all 10 csv+res must exist)."""
    if metric not in LATENCY_METRICS:
        raise ValueError(f"unknown metric {metric!r}")
    banned = BANNED_CONC.get((proto, mode), set())
    out = []
    for c in collect_concs(log_dir, proto, mode):
        if c in banned:
            continue
        if dc is None:
            agg = aggregate(log_dir, proto, c, mode, metric)
        else:
            agg = aggregate_dc(log_dir, proto, c, mode, dc, metric)
        if agg is None:
            continue
        tput, lat = agg
        out.append((c, tput, lat))
    out.sort(key=lambda r: r[0])
    return filter_latency_outliers(out)


# ------------------------------------------------------------------------
# Style — mirrors the OSDI throughput-latency plot
# ------------------------------------------------------------------------
plt.rcParams.update({
    "text.usetex": False,
    "font.family": "serif",
    "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
    "mathtext.fontset": "stix",
    "xtick.labelsize": 14,
    "ytick.labelsize": 14,
})

# (label, color, marker, linestyle) — matches the OSDI throughput-latency style.
# The 0% line is auto-skipped when rule_*@0 data is absent (true for all
# camera-ready folders; OSDI does have it for raft/copilot/mencius/mongodb).
PANEL_CONFIGS = [
    ("vanilla",  "#437c17", "^", "-"),
    ("0%",       "black",   "x", ":"),
    ("adaptive", "#B22222", "o", "--"),
    ("100%",     "orange",  "*", "-."),
]

LINE_WIDTH = 2.5
MARKER_SIZE = 9


def savefig_all(fig, pdf_path, **kwargs):
    fig.savefig(pdf_path, **kwargs)
    base, _ = os.path.splitext(pdf_path)
    fig.savefig(base + ".png", dpi=200, **kwargs)


# ------------------------------------------------------------------------
# Figure A — 1x5 row (Raft / Copilot / Mencius / MongoDB / etcd)
# ------------------------------------------------------------------------
GRID_PROTOCOLS = [
    ("Raft",      "raft"),
    ("etcd",      "etcd"),
    ("MongoDB",   "mongodb"),
    ("Copilot",   "copilot"),
    ("Mencius",   "mencius"),
]


# Per-panel line suppressions: (proto_root, panel_label) pairs to NOT draw.
# Use when a specific variant's data is too noisy or not yet trusted for that
# protocol; entry maps to "explicitly empty" in the returned series_map so the
# legend / panel still uses the same column slot.
SKIP_LINES = {
    # (proto_root, panel_label) pairs to NOT draw on this figure.
    # Empty as of 2026-05-09: the prior mongodb-0% suppression was added
    # because OSDI Dec 2025 mongodb @ c=40 m=0 had a 4488 ms saturation
    # spike; that data was archived when we swapped to June 2025 c=50,
    # and the current mongodb-0% line is clean (~285-300 ms across the
    # workload-axis).
}


def build_panel_series(log_dir, proto_root, metric="p90", dc=None):
    """Return dict keyed by config label -> series rows.
    The 0% entry will simply be empty for folders where rule_*@0 doesn't exist.
    Entries matching SKIP_LINES are forced empty to suppress that line."""
    sources = [
        ("vanilla",  f"none_{proto_root}", 0),
        ("0%",       f"rule_{proto_root}", 0),
        ("adaptive", f"rule_{proto_root}", 101),
        ("100%",     f"rule_{proto_root}", 100),
    ]
    out = {}
    for label, proto, mode in sources:
        if (proto_root, label) in SKIP_LINES:
            out[label] = []
            continue
        out[label] = series_for(log_dir, proto, mode, metric=metric, dc=dc)
    return out


def draw_grid_figure(log_dir, out_path, metric="p90", dc=None, dc_label=None):
    fig, axes = plt.subplots(1, 5, figsize=(25, 5.8), sharey=False)
    axes = axes.flatten()
    counts = []
    ylab = LATENCY_METRICS[metric][1]
    for ax, (title, root) in zip(axes, GRID_PROTOCOLS):
        series_map = build_panel_series(log_dir, root, metric=metric, dc=dc)
        n_pts = 0
        for label, color, marker, ls in PANEL_CONFIGS:
            rows = series_map.get(label, [])
            n_pts += len(rows)
            if not rows:
                continue
            xs = [r[1] for r in rows]
            ys = [r[2] for r in rows]
            ax.plot(xs, ys, label=label, color=color, marker=marker,
                    linestyle=ls, linewidth=LINE_WIDTH, ms=MARKER_SIZE)
        ax.set_title(title, fontsize=22)
        ax.set_xlabel("Throughput (ops/s)", fontsize=18)
        ax.set_ylabel(ylab, fontsize=18)
        ax.grid(True, linestyle="--", alpha=0.5)
        ax.set_ylim(0, 1500)
        ax.set_xlim(left=0)
        counts.append((title, n_pts))

    handles, labels = axes[0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper center", ncol=len(PANEL_CONFIGS),
                   bbox_to_anchor=(0.5, 0.99), frameon=True, fontsize=18,
                   handlelength=2.0, handletextpad=0.6, columnspacing=1.5)
    if dc_label:
        fig.suptitle(dc_label, fontsize=20, y=1.03)
    fig.subplots_adjust(left=0.05, right=0.99, top=0.84, bottom=0.16,
                        wspace=0.26)

    savefig_all(fig, out_path, bbox_inches="tight")
    plt.close(fig)
    return counts


# ------------------------------------------------------------------------
# Figure B — Raft variants vs CURP / SwiftPaxos / EPaxos
# ------------------------------------------------------------------------
COMPARE_LINES = [
    # (label,                     color,      marker, linestyle, proto,                   pct)
    ("Raft (vanilla)",            "#437c17",  "^",    "-",       "none_raft",              0),
    ("Raft + Jetpack (adaptive)", "#B22222",  "o",    "--",      "rule_raft",            101),
    ("CURP",                      "#1f77b4",  "D",    "-",       "none_curp",            200),
    ("Swift Paxos",               "#ff7f0e",  "P",    "-",       "none_swiftpaxos",        0),
    ("EPaxos",                    "#8c564b",  "X",    "-",       "none_epaxos_corrected",  0),
]


def draw_compare_figure(log_dir, out_path, metric="p90", dc=None, dc_label=None):
    fig, ax = plt.subplots(figsize=(10, 6.5))
    counts = []
    for label, color, marker, ls, proto, mode in COMPARE_LINES:
        rows = series_for(log_dir, proto, mode, metric=metric, dc=dc)
        counts.append((label, len(rows)))
        if not rows:
            continue
        xs = [r[1] for r in rows]
        ys = [r[2] for r in rows]
        ax.plot(xs, ys, label=label, color=color, marker=marker, linestyle=ls,
                linewidth=LINE_WIDTH, ms=MARKER_SIZE)
    ax.set_xlabel("Throughput (ops/s)", fontsize=20)
    ax.set_ylabel(LATENCY_METRICS[metric][1], fontsize=20)
    ax.grid(True, linestyle="--", alpha=0.5)
    ax.set_ylim(0, 2000)
    ax.set_xlim(left=0)
    if dc_label:
        ax.set_title(dc_label, fontsize=18)
    ax.legend(fontsize=14, loc="upper left", framealpha=0.95)
    fig.tight_layout()
    savefig_all(fig, out_path, bbox_inches="tight")
    plt.close(fig)
    return counts


# ------------------------------------------------------------------------
# Per-DC mapping
# ------------------------------------------------------------------------
DC_NAMES = [
    "CA",  "OR",  "MUM", "FF",  "STO",
    "LDN", "HK",  "SGP", "IRL", "PAR",
]
PER_DC_FOLDERS = {"2026-05-05-merged-cameraready"}


# ------------------------------------------------------------------------
# Driver
# ------------------------------------------------------------------------
DEFAULT_FOLDERS = [
    "2026-04-30-camera-ready-exp0-small.usable",
    "2026-05-02-camera-ready-exp0-fixes",
    "2026-05-05-merged-cameraready",
]
RESULTS_ROOT = "/home/users/ztang/janus/results"


def run_one(result_dir):
    log_dir = os.path.join(result_dir, "log")
    figs_dir = os.path.join(result_dir, "figs")
    os.makedirs(figs_dir, exist_ok=True)
    if not os.path.isdir(log_dir):
        print(f"[SKIP] {result_dir}: no log/ dir")
        return

    folder_name = os.path.basename(result_dir.rstrip("/"))
    print(f"\n=== {folder_name} ===")

    n_lines = len(PANEL_CONFIGS)
    do_per_dc = folder_name in PER_DC_FOLDERS

    for metric, (_idx, ylab, slug) in LATENCY_METRICS.items():
        print(f"\n  -- metric: {metric} ({ylab}) --")

        # Cluster-aggregate
        grid_path = os.path.join(figs_dir, f"tput_{slug}_latency_grid.pdf")
        grid_counts = draw_grid_figure(log_dir, grid_path, metric=metric)
        print(f"    [GRID] {grid_path}")
        for title, n in grid_counts:
            print(f"      {title:<10} -> {n} pts (up to {n_lines} lines)")

        cmp_path = os.path.join(figs_dir, f"tput_{slug}_raft_curp_swiftpaxos_epaxos.pdf")
        cmp_counts = draw_compare_figure(log_dir, cmp_path, metric=metric)
        print(f"    [CMP]  {cmp_path}")
        for label, n in cmp_counts:
            print(f"      {label:<32} -> {n} pts")

        if do_per_dc:
            for dc, name in enumerate(DC_NAMES):
                tag = f"dc{dc}_{name}"
                grid_p = os.path.join(figs_dir, f"tput_{slug}_latency_grid_{tag}.pdf")
                draw_grid_figure(log_dir, grid_p, metric=metric,
                                 dc=dc, dc_label=f"DC{dc} ({name}) view")
                cmp_p = os.path.join(figs_dir, f"tput_{slug}_raft_curp_swiftpaxos_epaxos_{tag}.pdf")
                draw_compare_figure(log_dir, cmp_p, metric=metric,
                                    dc=dc, dc_label=f"DC{dc} ({name}) view")
            print(f"    [DCs]  10 per-DC pairs written for metric {metric}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--result-dir", action="append",
                    help="Absolute or basename path under results/. Repeatable.")
    args = ap.parse_args()

    folders = args.result_dir or DEFAULT_FOLDERS
    for f in folders:
        if os.path.isabs(f):
            run_one(f)
        else:
            run_one(os.path.join(RESULTS_ROOT, f))


if __name__ == "__main__":
    main()
