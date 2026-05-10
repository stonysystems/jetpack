#!/usr/bin/env python3
"""
Workload-axis figures: latency / throughput at fixed near-saturation
concurrency, varying the workload (zipf-skew or key-range).

Mirrors the layout-style of `gen_tput_p90_figures.py` but with the *workload*
on the x-axis instead of concurrency. Inspired by the OSDI 2025-12-11
notebook's `latency_ae_ave_on_zipf_skew_*.pdf` / `latency_ae_ave_on_key_range_*.pdf`
figures (cells 20-21), which were a 2x2 grid for 4 protocols. This version
extends to 5 protocols (adds etcd) and uses a 1x5 row to match the camera-
ready throughput-latency / latency-CDF grids.

Per folder (passed as --result-dir or auto-discovered), produces in <folder>/figs/:
  * latency_<metric>_vs_zipf.{pdf,png}     (metric in {p50,p90,p99,ave})
  * latency_<metric>_vs_keyrange.{pdf,png}
  * tput_vs_zipf.{pdf,png}
  * tput_vs_keyrange.{pdf,png}
  * fp_success_rate.{pdf,png}              (combined two-panel figure:
    left = zipf, right = key-range. One adaptive line per protocol, conc
    annotated in the shared legend; vanilla has no fast path.)

Each panel = one protocol at its fixed near-saturation conc; lines are
{vanilla = none_<proto>@0, adaptive = rule_<proto>@101} per the OSDI
"print" version (m=100 dropped). Empty panels (e.g. etcd today, which
has no workload-axis data yet) are drawn with title + axes; the script
prints a per-cell warning when data is missing so it's clear what's
pending.

A data point is included only if all 10 .csv AND all 10 .res files exist
for that prefix AND every host's .res file parses cleanly with both
"Mid throughput" and "All-efficient-attempts ... ave".

Throughput  = sum of "Mid throughput" across the 10 client hosts.
Latency     = median across the 10 host values for the chosen percentile
              (matches the gen_tput_p90_figures.py convention).
"""

import argparse
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ------------------------------------------------------------------------
# Parsing — mirrors gen_tput_p90_figures.py
# ------------------------------------------------------------------------
MID_RE  = re.compile(r"Mid throughput is\s+([0-9.]+)")
STAT_RE = re.compile(
    r"All-efficient-attempts\s+statistics\s+count\s+\d+\s+"
    r"0pct\s+([0-9.]+)\s+50pct\s+([0-9.]+)\s+90pct\s+([0-9.]+)\s+"
    r"99pct\s+([0-9.]+)\s+ave\s+([0-9.]+)"
)
# Per-host fast-path counters. Each .res emits one "All-fast-path-attempts" /
# "Success-fast-path-attempts" / "Efficient-fast-path-attempts" line per
# stats-print interval; we want the LAST occurrence (final/cumulative).
FP_ATTEMPT_RE = re.compile(r"All-fast-path-attempts\s+statistics\s+count\s+(\d+)")
FP_SUCCESS_RE = re.compile(r"Success-fast-path-attempts\s+statistics\s+count\s+(\d+)")
FP_EFFICIENT_RE = re.compile(r"Efficient-fast-path-attempts\s+statistics\s+count\s+(\d+)")
ERR_RE  = re.compile(r"generic server error")
DUMP_RE = re.compile(r"Dumped to")
NHOSTS  = 10

LATENCY_METRICS = {
    "p50": (2, "p50 Latency (ms)", "p50"),
    "p90": (3, "p90 Latency (ms)", "p90"),
    "p99": (4, "p99 Latency (ms)", "p99"),
    "ave": (5, "Average Latency (ms)", "ave"),
}


def parse_res(path):
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
    # Fast-path counters: pick the LAST occurrence (cumulative final). Vanilla
    # mode-0 .res files don't emit these — we return zeros so the aggregate
    # success_rate evaluates to 0 (or None if attempts==0, handled by caller).
    fp_attempt = FP_ATTEMPT_RE.findall(txt)
    fp_success = FP_SUCCESS_RE.findall(txt)
    fp_efficient = FP_EFFICIENT_RE.findall(txt)
    fp = {
        "attempts":   int(fp_attempt[-1])   if fp_attempt   else 0,
        "successes":  int(fp_success[-1])   if fp_success   else 0,
        "efficient":  int(fp_efficient[-1]) if fp_efficient else 0,
    }
    return (float(m_mid.group(1)), lat, fp)


_AGG_CACHE = {}


def aggregate_rows(log_dir, proto, workload, conc, mode):
    """Return [(mid_tput, lat_dict), ...] of length 10, or None if the
    cluster-completeness gate is not met (any of the 20 csv/res missing
    or unparseable)."""
    key = (log_dir, proto, workload, conc, mode)
    if key in _AGG_CACHE:
        return _AGG_CACHE[key]
    rows = []
    for i in range(NHOSTS):
        prefix = f"{proto}-60c1s5r10p-{workload}-concurrent_{conc}-{mode}-YCSB_A-server{i}"
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


# Per-(proto, conc, workload, mode) ban list for the workload-axis figures.
# Was needed for the OSDI Dec 2025 alt_workloads sweep (mongodb @ c=40)
# which had several 2-10x flap cells, but the 2025-06-26 mongodb data
# (restored 2026-05-10) is clean across all workloads, so this list is
# now empty. Kept the dict here so future flaps can be banned per cell
# without rewriting the aggregate() helper.
BANNED_WORKLOAD_CELLS = {}


def aggregate(log_dir, proto, workload, conc, mode, metric):
    if (proto, conc, workload, mode) in BANNED_WORKLOAD_CELLS:
        return None
    rows = aggregate_rows(log_dir, proto, workload, conc, mode)
    if rows is None:
        return None
    tput = sum(r[0] for r in rows)
    vals = sorted(r[1][metric] for r in rows)
    med  = 0.5 * (vals[NHOSTS // 2 - 1] + vals[NHOSTS // 2])
    return tput, med


def aggregate_fp_rate(log_dir, proto, workload, conc, mode, kind="success"):
    """Returns the cluster-wide fast-path rate (%) or None if data missing.
    kind in {"success", "efficient"}:
      success   = sum(successes)  / sum(attempts) * 100
      efficient = sum(efficient)  / sum(attempts) * 100
    Returns None if attempts sum to 0 (e.g. vanilla cells with no fast path)."""
    rows = aggregate_rows(log_dir, proto, workload, conc, mode)
    if rows is None:
        return None
    total_attempts  = sum(r[2]["attempts"]  for r in rows)
    total_successes = sum(r[2]["successes"] for r in rows)
    total_efficient = sum(r[2]["efficient"] for r in rows)
    if total_attempts == 0:
        return None
    if kind == "success":
        return 100.0 * total_successes / total_attempts
    if kind == "efficient":
        return 100.0 * total_efficient / total_attempts
    raise ValueError(f"unknown fp-rate kind {kind!r}")


# ------------------------------------------------------------------------
# Configuration — protocols, fixed concurrencies, workload axes
# ------------------------------------------------------------------------
# Display name | proto root | fixed near-saturation conc for this figure
# Conc choice:
#   - raft / copilot @ 50, mencius @ 25: matches the v2 TODO (workload-axis
#     sweeps) and lands well inside the linear region for those protocols.
#   - mongodb @ 50: matches OSDI Figure 11's `contention_fixed_conc_number`
#     (the contention dataset, June-July 2025). The earlier 2026-05-08 merge
#     copied OSDI's December 2025 alt-workload runs at c=40 (auxiliary side
#     experiment, partially saturated); the cleaner June-July 2025 sweep
#     at c=50 was pulled in 2026-05-09 from
#     /home/users/ztang/JetPack-Scripts/results/2025-06-26-...x2025-07-03-...
#   - etcd @ 50: chosen to match the latency-CDF script's anchor; no
#     workload-axis data exists yet, so this is just a placeholder until
#     an etcd zipf/key-range sweep runs.
PROTOCOLS = [
    ("Raft",     "raft",     50),
    ("etcd",     "etcd",     50),
    # MongoDB: c=50 matches the 2025-06-26 merged jetpack-paper dataset
    # (the source of the camera-ready figure). Swapped 2026-05-10 from the
    # OSDI Dec 2025 alt_workloads (c=40, had flap cells) to the older but
    # cleaner 2025-06-26 sweep that produced the published OSDI Figure 7.
    ("MongoDB",  "mongodb",  50),
    ("Copilot",  "copilot",  50),
    # Mencius @ c=10 is the camera-ready default (2026-05-10): the c=10
    # battery covers all 11 workloads × 3 modes; c=16 figures are
    # explicitly NOT generated (per user directive 2026-05-10).
    ("Mencius",  "mencius",  10),
]

# Lines drawn per panel. (label, color, marker, linestyle, proto_prefix_fmt, mode)
# {{root}} substitutes the protocol root from PROTOCOLS. linestyles match
# OSDI cell 10 (adaptive uses dash-dot).
LINE_CONFIGS = [
    ("vanilla",  "#437c17", "^", "-",  "none_{root}",   0),
    ("0%",       "black",   "x", ":",  "rule_{root}",   0),
    ("adaptive", "#B22222", "o", "-.", "rule_{root}", 101),
]

# Per-protocol palette for the combined fast-path success-rate figure
# (all 5 protocols on a single axes, one line each = adaptive m=101).
PROTOCOL_STYLE = {
    "raft":     ("#B22222", "o", "-"),
    "copilot":  ("#1f77b4", "D", "-"),
    "mencius":  ("#9467bd", "s", "-"),
    "mongodb":  ("#ff7f0e", "P", "-"),
    "etcd":     ("#2ca02c", "X", "-"),
}

# Workload axes — the values we plot at, plus how to render them on the x-axis.
ZIPF_LEVELS = [
    ("rw_zipf_0.5", "0.5"),
    ("rw_zipf_0.6", "0.6"),
    ("rw_zipf_0.7", "0.7"),
    ("rw_zipf_0.8", "0.8"),
    ("rw_zipf_0.9", "0.9"),
    ("rw_zipf_1",   "1.0"),
]
# Key-range axis: start at 10^2. Smaller key ranges (rw_1 / rw_10) are
# degenerate hot-key cases that don't add information; OSDI's notebook also
# drops them (see cell 21, contention_key_range_workloads[2:]).
KEYRANGE_LEVELS = [
    ("rw_100",     r"$10^2$"),
    ("rw_1000",    r"$10^3$"),
    ("rw_10000",   r"$10^4$"),
    ("rw_100000",  r"$10^5$"),
    ("rw_1000000", r"$10^6$"),
]

# OSDI cell 10 numeric defaults (used by zipf cell 20 and keyrange cell 21).
LINE_WIDTH       = 2
MARKER_SIZE      = 10
TITLE_FONT_SIZE  = 24
XLABEL_FONT_SIZE = 20
YLABEL_FONT_SIZE = 20
LEGEND_FONT_SIZE = 15

plt.rcParams.update({
    "text.usetex": False,
    "font.family": "serif",
    "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
    "mathtext.fontset": "stix",
    "xtick.labelsize": 18,
    "ytick.labelsize": 18,
})


# ------------------------------------------------------------------------
# Plotting
# ------------------------------------------------------------------------
def savefig_all(fig, pdf_path, **kwargs):
    fig.savefig(pdf_path, **kwargs)
    base, _ = os.path.splitext(pdf_path)
    fig.savefig(base + ".png", dpi=200, **kwargs)


def _plot_fp_rate_on_ax(ax, log_dir, axis_label, axis_name, levels,
                        fp_rate="success", ylim=(0, 102),
                        ylabel=None, protocols=None):
    """Plot one fp-rate panel onto an existing axes. Returns (counts, handles, labels)
    where counts is a list of (protocol_title, lines_drawn) and handles/labels
    are matplotlib's so the caller can build a shared legend across panels."""
    n = len(levels)
    x_idx = np.arange(n)
    x_tick_labels = [x_label for (_, x_label) in levels]
    counts = []
    handles, labels = [], []
    if protocols is None:
        protocols = PROTOCOLS
    for (title, root, conc) in protocols:
        proto = f"rule_{root}"
        mode = 101
        ys = np.full(n, np.nan)
        missing = []
        for i, (wl, _) in enumerate(levels):
            v = aggregate_fp_rate(log_dir, proto, wl, conc, mode, kind=fp_rate)
            if v is None:
                missing.append(wl)
                continue
            ys[i] = v
        if missing:
            print(f"    [missing] {title} adaptive (proto={proto} m={mode} c={conc}): "
                  f"{len(missing)} of {n} {axis_name} cells absent "
                  f"({', '.join(missing)})")
        if not np.isfinite(ys).any():
            counts.append((title, 0))
            continue
        color, marker, ls = PROTOCOL_STYLE.get(root, ("#444444", "o", "-"))
        label = f"{title} (c={conc})"
        line, = ax.plot(x_idx, ys, label=label, color=color, marker=marker,
                        linestyle=ls, linewidth=LINE_WIDTH, ms=MARKER_SIZE)
        handles.append(line)
        labels.append(label)
        counts.append((title, 1))
    ax.set_xlabel(axis_label, fontsize=18)
    if ylabel is not None:
        ax.set_ylabel(ylabel, fontsize=18)
    ax.set_xticks(x_idx)
    ax.set_xticklabels(x_tick_labels)
    ax.set_xlim(-0.3, n - 0.7)
    ax.grid(True, linestyle="--", alpha=0.5)
    ax.set_ylim(*ylim)
    return counts, handles, labels


def draw_combined_fp_rate_two_axes(log_dir, out_path,
                                   left_levels, left_label, left_name,
                                   right_levels, right_label, right_name,
                                   fp_rate="success",
                                   ylabel="Fast-path success rate (%)",
                                   ylim=(0, 102),
                                   protocols=None):
    """Two-panel figure: left = zipf-skew axis, right = key-range axis. Each
    panel draws one adaptive line per protocol (conc annotated in the legend).
    Single shared legend at the top of the figure."""
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))
    left_counts, lh, ll = _plot_fp_rate_on_ax(
        axes[0], log_dir, left_label, left_name, left_levels,
        fp_rate=fp_rate, ylim=ylim, ylabel=ylabel, protocols=protocols)
    right_counts, rh, rl = _plot_fp_rate_on_ax(
        axes[1], log_dir, right_label, right_name, right_levels,
        fp_rate=fp_rate, ylim=ylim, ylabel=None, protocols=protocols)
    # Build the shared legend from whichever panel has more lines.
    handles, labels = (lh, ll) if len(lh) >= len(rh) else (rh, rl)
    if handles:
        fig.legend(handles, labels, loc="upper center", ncol=len(handles),
                   bbox_to_anchor=(0.5, 1.02), frameon=True, fontsize=14,
                   handlelength=2.0, handletextpad=0.6, columnspacing=1.2)
    fig.subplots_adjust(left=0.08, right=0.99, top=0.86, bottom=0.13,
                        wspace=0.20)
    savefig_all(fig, out_path, bbox_inches="tight")
    plt.close(fig)
    return [("zipf",     left_counts),
            ("keyrange", right_counts)]


def draw_dual_metric_grid(log_dir, out_path, axis_label, axis_name, levels,
                          metrics_pair=("ave", "p99"), ylim=(120, 550),
                          protocols=None, figsize=(24, 6), show_legend=False,
                          xtick_size=None, top=None, legend_y=1.04):
    """**Stacked** (2-row × N-column) dual-metric figure:
    top row    = metrics_pair[0] (default "ave") for each protocol
    bottom row = metrics_pair[1] (default "p99") for each protocol

    Per-row design (set 2026-05-10 by user):
      - Titles on the TOP row only (just protocol name; no "(avg)/(p99)"
        suffix). Bottom row's panels have no title.
      - Y-labels: top row's leftmost = "Avg. Lat. (ms)"; bottom row's
        leftmost = "p99 Lat. (ms)" (or whatever metrics_pair maps to).
      - X-tick labels and the single centered axis_label go on the
        BOTTOM row only.
      - Both rows share x-axis (sharex=True via column linkage); each
        row has its own y-axis (sharey applies per row, not across rows).
      - Y-axis defaults to (120, 550) so the floor sits a bit below the
        cleanest adaptive lines (~150 ms).

    figsize stretched vertically to ~6" (was 3) since we now have two rows.
    """
    METRIC_LABEL = {"ave": "Avg. Lat. (ms)", "p50": "p50 Lat. (ms)",
                    "p90": "p90 Lat. (ms)", "p99": "p99 Lat. (ms)"}
    if protocols is None:
        protocols = PROTOCOLS
    n_panels = len(protocols)
    fig, axes = plt.subplots(2, n_panels, figsize=figsize,
                             sharex="col")  # share x per column; sharey handled manually

    n = len(levels)
    x_idx = np.arange(n)
    x_tick_labels = [x_label for (_, x_label) in levels]

    for row_idx, metric in enumerate(metrics_pair):
        # Row-internal sharey: link all panels in this row by setting the
        # same ylim AFTER plotting, and only show y-tick labels on the
        # leftmost panel of each row.
        for col_idx, (title, root, conc) in enumerate(protocols):
            ax = axes[row_idx, col_idx]
            for (label, color, marker, ls, proto_fmt, mode) in LINE_CONFIGS:
                proto = proto_fmt.format(root=root)
                ys = np.full(n, np.nan)
                for i, (wl, _) in enumerate(levels):
                    agg = aggregate(log_dir, proto, wl, conc, mode, metric)
                    if agg is None:
                        continue
                    ys[i] = agg[1]
                if np.isfinite(ys).any():
                    ax.plot(x_idx, ys, label=label, color=color, marker=marker,
                            linestyle=ls, linewidth=LINE_WIDTH, ms=MARKER_SIZE)
            # Title only on the top row; just protocol name, no metric suffix.
            if row_idx == 0:
                ax.set_title(title, fontsize=26)
            ax.set_xticks(x_idx)
            # X-tick labels only on bottom row (top row gets blank ticks via
            # sharex, but we must explicitly clear them just in case).
            if row_idx == len(metrics_pair) - 1:
                ax.set_xticklabels(x_tick_labels)
                if xtick_size is not None:
                    ax.tick_params(axis="x", labelsize=xtick_size)
            ax.set_xlim(-0.3, n - 0.7)
            ax.grid(True, linestyle="--", alpha=0.5)
            ax.set_ylim(*ylim)
            # Hide y-tick labels except on the leftmost panel of each row.
            if col_idx > 0:
                ax.tick_params(axis="y", labelleft=False)
        # Per-row y-axis label on the leftmost panel.
        axes[row_idx, 0].set_ylabel(METRIC_LABEL.get(metric, metric),
                                    fontsize=YLABEL_FONT_SIZE)

    if show_legend:
        handles, labels = axes[0, 0].get_legend_handles_labels()
        if handles:
            fig.legend(handles, labels, loc="upper center", ncol=len(handles),
                       bbox_to_anchor=(0.5, legend_y), frameon=True, fontsize=24)
        fig.subplots_adjust(left=0.05, right=0.99, bottom=0.13,
                            top=top if top is not None else 0.86,
                            wspace=0.05, hspace=0.10)
    else:
        fig.subplots_adjust(left=0.05, right=0.99, bottom=0.13,
                            top=top if top is not None else 0.93,
                            wspace=0.05, hspace=0.10)

    # Single centered x-axis label below the bottom row only.
    fig.canvas.draw()
    bottom_axes = axes[-1, :]
    xc = (bottom_axes[0].get_position().x0 + bottom_axes[-1].get_position().x1) / 2
    label_y = 0.02
    fig.text(xc, label_y, axis_label, ha="center", va="bottom",
             fontsize=XLABEL_FONT_SIZE)

    savefig_all(fig, out_path, bbox_inches="tight", pad_inches=0.02)
    plt.close(fig)
    return None


def draw_grid(log_dir, out_path, axis_label, axis_name, levels, metric=None,
              tput=False, fp_rate=None, ylim=None, ylabel=None,
              skip_line_labels=(), protocols=None):
    """Draw a 1x5 grid: x = workload level (zipf or key-range),
    y = metric value (latency-ms / throughput-ops/s / fast-path rate-%).

    `levels` = [(workload_id, x_label), ...].
    `metric` = key into LATENCY_METRICS (used when tput=False and fp_rate=None).
    `tput=True`     switches the y-axis to throughput (sum across 10 hosts).
    `fp_rate`       in {None, "success", "efficient"}: switches y-axis to a
                    cluster-wide fast-path rate (%). Vanilla lines naturally
                    return None (no fast-path counters), and `skip_line_labels`
                    can be used to suppress them up front.
    `skip_line_labels` = a tuple of LINE_CONFIGS labels to NOT draw on this
                    figure (e.g. ("vanilla",) for the fp_rate panels).
    """
    if protocols is None:
        protocols = PROTOCOLS
    n_panels = len(protocols)
    # Figure 11 published aspect (per the OSDI paper): tight wide row, similar
    # to the CDF figure (cell 14 figsize=(24,3) for 1×4 = 6×3 per panel).
    fig, axes = plt.subplots(1, n_panels, figsize=(6 * n_panels, 3), sharey=True)
    if n_panels == 1:
        axes = [axes]
    counts = []
    # Use integer x-positions + explicit tick labels so missing cells leave
    # a gap instead of reshuffling the categorical axis. (Matplotlib treats
    # string x-coords as categories ordered by first-seen, which means a
    # later line's missing-from-earlier-line value lands at the right end —
    # the symptom: rw_100 ends up after rw_1000000 if Raft vanilla skipped
    # it but Raft adaptive didn't. Integer positions + NaN gaps fix this.)
    n = len(levels)
    x_idx = np.arange(n)
    x_tick_labels = [x_label for (_, x_label) in levels]
    for ax, (title, root, conc) in zip(axes, protocols):
        n_lines_drawn = 0
        for (label, color, marker, ls, proto_fmt, mode) in LINE_CONFIGS:
            if label in skip_line_labels:
                continue
            proto = proto_fmt.format(root=root)
            ys = np.full(n, np.nan)
            missing = []
            for i, (wl, _) in enumerate(levels):
                if fp_rate is not None:
                    v = aggregate_fp_rate(log_dir, proto, wl, conc, mode, kind=fp_rate)
                    if v is None:
                        missing.append(wl)
                        continue
                    ys[i] = v
                else:
                    agg = aggregate(log_dir, proto, wl, conc, mode, metric)
                    if agg is None:
                        missing.append(wl)
                        continue
                    ys[i] = agg[0] if tput else agg[1]
            if missing:
                print(f"    [missing] {title} {label} (proto={proto} m={mode} c={conc}): "
                      f"{len(missing)} of {n} {axis_name} cells absent "
                      f"({', '.join(missing)})")
            if np.isfinite(ys).any():
                ax.plot(x_idx, ys, label=label, color=color, marker=marker,
                        linestyle=ls, linewidth=LINE_WIDTH, ms=MARKER_SIZE)
                n_lines_drawn += 1
        ax.set_title(f"{title} (c={conc})", fontsize=26)
        ax.set_xlabel(axis_label, fontsize=XLABEL_FONT_SIZE)
        ax.set_xticks(x_idx)
        ax.set_xticklabels(x_tick_labels)
        ax.set_xlim(-0.3, n - 0.7)
        ax.grid(True, linestyle="--", alpha=0.5)
        if ylim is not None:
            ax.set_ylim(*ylim)
        else:
            ax.set_ylim(bottom=0)
        counts.append((title, n_lines_drawn))

    # OSDI Figure 11 layout: y-label only on first panel; hide y-tick labels
    # on axes[1:] (shared y).
    if ylabel is not None:
        axes[0].set_ylabel(ylabel, fontsize=YLABEL_FONT_SIZE)
    elif tput:
        axes[0].set_ylabel("Throughput (ops/s)", fontsize=YLABEL_FONT_SIZE)
    else:
        axes[0].set_ylabel(LATENCY_METRICS[metric][1], fontsize=YLABEL_FONT_SIZE)
    for ax in axes[1:]:
        ax.tick_params(labelleft=False)

    # Top-center fig.legend (matches OSDI Figure 11's tight published layout).
    handles, labels = axes[0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper center", ncol=len(handles),
                   bbox_to_anchor=(0.5, 0.97), frameon=True, fontsize=24)
    fig.subplots_adjust(left=0.05, right=0.99, bottom=0.27, top=0.70,
                        wspace=0.05)
    savefig_all(fig, out_path, bbox_inches="tight", pad_inches=0.02)
    plt.close(fig)
    return counts


# ------------------------------------------------------------------------
# Driver
# ------------------------------------------------------------------------
DEFAULT_FOLDERS = [
    "2026-05-05-camera-ready-exp0-fixes-v2",
]
RESULTS_ROOT = "/home/users/ztang/janus/results"


def run_one(result_dir):
    """Generate the workload-axis figure suite under result_dir/figs/."""
    log_dir = os.path.join(result_dir, "log")
    figs_dir = os.path.join(result_dir, "figs")
    os.makedirs(figs_dir, exist_ok=True)
    if not os.path.isdir(log_dir):
        print(f"[SKIP] {result_dir}: no log/ dir")
        return

    folder_name = os.path.basename(result_dir.rstrip("/"))
    print(f"\n=== {folder_name} ===")

    protocols_local = [tuple(p) for p in PROTOCOLS]

    axes_specs = [
        ("zipf",     ZIPF_LEVELS,     "Zipfian Skew Parameter (θ)", "zipf"),
        ("keyrange", KEYRANGE_LEVELS, "Key Range",                   "keyrange"),
    ]

    # Run each figure twice: once with all 5 protocols (no suffix), once
    # with etcd dropped (suffix `_noetcd`). Set 2026-05-09 to give a
    # without-etcd alternative for the writeup.
    PROTO_PASSES = (
        ("",        protocols_local),
        ("_noetcd", [p for p in protocols_local if p[1] != "etcd"]),
    )

    for axis_slug, levels, axis_label, axis_name in axes_specs:
        # latency panels (one figure per metric).
        # y-axis 150-550 ms across all latency metrics for the workload-axis
        # figures (set 2026-05-09 by user) — workload-axis runs are at fixed
        # near-saturation conc, the band that holds the bulk of points.
        for metric in ("p50", "p90", "p99", "ave"):
            for fname_suffix, protocols in PROTO_PASSES:
                out = os.path.join(figs_dir, f"latency_{metric}_vs_{axis_slug}{fname_suffix}.pdf")
                ylim = (150, 550)
                print(f"  [{axis_slug}/{metric}{fname_suffix}] -> {out}")
                counts = draw_grid(log_dir, out,
                                   axis_label=axis_label, axis_name=axis_name,
                                   levels=levels, metric=metric, tput=False,
                                   ylim=ylim, protocols=protocols)
                for title, n in counts:
                    print(f"    {title:<10} -> {n} lines drawn")

        # throughput panel (one figure per axis)
        for fname_suffix, protocols in PROTO_PASSES:
            out_t = os.path.join(figs_dir, f"tput_vs_{axis_slug}{fname_suffix}.pdf")
            print(f"  [{axis_slug}/tput{fname_suffix}] -> {out_t}")
            counts = draw_grid(log_dir, out_t,
                               axis_label=axis_label, axis_name=axis_name,
                               levels=levels, metric="ave", tput=True, ylim=None,
                               protocols=protocols)
            for title, n in counts:
                print(f"    {title:<10} -> {n} lines drawn")

    # Combined dual-metric workload-axis figures (no-etcd only) — set
    # 2026-05-10 layout: stacked (2 rows × 4 cols) — top row = avg, bottom
    # row = p99. Single x-axis label centered under the bottom row.
    noetcd_protocols = [p for p in protocols_local if p[1] != "etcd"]
    DUAL_PER_AXIS = {
        # zipf has 6 dense ticks per panel (0.5..1.0) → smaller xtick label,
        # legend lives above the figure.
        "zipf":     dict(figsize=(24, 7), show_legend=True,
                         xtick_size=14, top=0.84, legend_y=1.00),
        "keyrange": dict(figsize=(24, 6),   show_legend=False,
                         xtick_size=None, top=None, legend_y=None),
    }
    for axis_slug, levels, axis_label, axis_name in axes_specs:
        out = os.path.join(figs_dir, f"latency_ave_p99_vs_{axis_slug}_noetcd.pdf")
        opts = DUAL_PER_AXIS[axis_slug]
        print(f"  [{axis_slug}/ave+p99 dual_noetcd figsize={opts['figsize']} legend={opts['show_legend']}] -> {out}")
        draw_dual_metric_grid(log_dir, out,
                              axis_label=axis_label, axis_name=axis_name,
                              levels=levels, metrics_pair=("ave", "p99"),
                              ylim=(120, 550), protocols=noetcd_protocols,
                              **opts)

    # Combined fast-path success-rate figure: two-panel (zipf | keyrange),
    # one adaptive line per protocol. Same dual emit (with/without etcd).
    for fname_suffix, protocols in PROTO_PASSES:
        out_fp = os.path.join(figs_dir, f"fp_success_rate{fname_suffix}.pdf")
        print(f"  [fp_success_rate{fname_suffix} (zipf | keyrange)] -> {out_fp}")
        summary = draw_combined_fp_rate_two_axes(
            log_dir, out_fp,
            left_levels=ZIPF_LEVELS,
            left_label="Zipfian Skew Parameter (θ)", left_name="zipf",
            right_levels=KEYRANGE_LEVELS,
            right_label="Key Range", right_name="keyrange",
            protocols=protocols,
        )
        for axis_label, counts in summary:
            for title, n in counts:
                print(f"    {axis_label:<10} {title:<10} -> {n} lines drawn")



def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--result-dir", action="append",
                    help="Absolute or basename path under results/. Repeatable.")
    args = ap.parse_args()
    folders = args.result_dir or DEFAULT_FOLDERS
    for f in folders:
        path = f if os.path.isabs(f) else os.path.join(RESULTS_ROOT, f)
        run_one(path)


if __name__ == "__main__":
    main()
