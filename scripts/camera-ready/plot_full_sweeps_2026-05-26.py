#!/usr/bin/env python3
"""Three tput-latency figures from the 2026-05-26 full-sweep session.

1. etcd 4-line batched grid — vanilla / fp0 / fp100 / adaptive at
   c={1,50,100,150,200,300}, all with etcd_batch_size=16 + timeout_ms=5.
   Source: log/_etcd_full_batched_sweep_2026-05-26/

2. ZooKeeper 4-line grid — same 4 variants × same concs, with
   pool=2500 + maxClientCnxns=3000.
   Source: log/_zookeeper_full_sweep_2026-05-26/

3. Raft batch-OFF + pipe-ON vs batch-ON + pipe-OFF — side-by-side panel
   comparing the two Raft build configurations across 4 variants.
   Sources:
     batch-OFF (today)  : results/2026-05-26-raft-batchoff-pipeon-full/
     batch-ON (shipping): results/2026-05-05-camera-ready-exp0-fixes-v2/log/
"""
import os
import re
import statistics
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT_DIR = "/home/users/ztang/janus/results/2026-05-13-camera-ready-exp0-fixes-v3/figs"
LOG_TOP = "/home/users/ztang/janus/results/2026-05-13-camera-ready-exp0-fixes-v3/log"

ETCD_DIR = f"{LOG_TOP}/_etcd_full_batched_sweep_2026-05-26"
ZK_DIR = f"{LOG_TOP}/_zookeeper_full_sweep_2026-05-26"
RAFT_BATCHOFF_DIR = "/home/users/ztang/janus/results/2026-05-26-raft-batchoff-pipeon-full"
RAFT_BATCHON_DIR = "/home/users/ztang/janus/results/2026-05-05-camera-ready-exp0-fixes-v2/log"

CONCS = [1, 50, 100, 150, 200, 300]
VARIANTS = [
    ("vanilla",  "none_",  0,   "#437c17", "^", "-"),
    ("fp0",      "rule_",  0,   "black",   "x", ":"),
    ("adaptive", "rule_",  101, "#B22222", "o", "-."),
    ("fp100",    "rule_",  100, "orange",  "*", "--"),
]


def parse_one(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        text = f.read()
    out = {}
    m = re.search(r"Mid throughput is\s+([\d.]+)", text)
    if m:
        out["tput"] = float(m.group(1))
    m = re.search(
        r"Read-mid-10s\s+statistics\s+count\s+(\d+)\s+0pct\s+([-\d.]+)"
        r"\s+50pct\s+([-\d.]+)\s+90pct\s+([-\d.]+)\s+99pct\s+([-\d.]+)\s+ave\s+([-\d.]+)",
        text,
    )
    if m:
        out["p50"] = float(m.group(3))
        out["p90"] = float(m.group(4))
        out["p99"] = float(m.group(5))
    return out


def agg(dir_path, proto, mode, conc):
    rows = []
    for i in range(10):
        p = os.path.join(
            dir_path,
            f"{proto}-60c1s5r10p-rw_1000000-concurrent_{conc}-{mode}-YCSB_A-server{i}.res",
        )
        d = parse_one(p)
        if d:
            rows.append(d)
    if not rows:
        return None
    tputs = [r["tput"] for r in rows if "tput" in r]
    p90s = [r["p90"] for r in rows if "p90" in r]
    if not tputs or not p90s:
        return None
    return sum(tputs), statistics.median(p90s)


def build_series(dir_path, backend_name):
    """Returns dict: variant_label -> [(c, tput, p90), ...]"""
    out = {}
    for label, prefix, mode, *_ in VARIANTS:
        proto = f"{prefix}{backend_name}"
        pts = []
        for c in CONCS:
            r = agg(dir_path, proto, mode, c)
            if r is None:
                continue
            pts.append((c, r[0], r[1]))
        if pts:
            out[label] = pts
    return out


# Style — matches gen_tput_p90_figures.py
plt.rcParams.update({
    "text.usetex": False,
    "font.family": "serif",
    "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
    "mathtext.fontset": "stix",
    "xtick.labelsize": 16,
    "ytick.labelsize": 16,
})
LINE_WIDTH = 3
MARKER_SIZE = 11


def plot_single_panel(ax, series, title, ylim_top=None, annotate=False):
    for label, _prefix, _mode, color, marker, ls in VARIANTS:
        pts = series.get(label, [])
        if not pts:
            continue
        xs = [p[1] for p in pts]
        ys = [p[2] for p in pts]
        ax.plot(xs, ys, label=label, color=color, marker=marker, linestyle=ls,
                linewidth=LINE_WIDTH, ms=MARKER_SIZE)
        if annotate:
            for c, x, y in pts:
                ax.annotate(f"c={c}", (x, y), textcoords="offset points",
                            xytext=(5, 4), fontsize=8, color=color)
    ax.set_xlabel("Throughput (ops/s)", fontsize=18)
    ax.set_ylabel("Read mid-10s p90 (ms)", fontsize=18)
    ax.set_title(title, fontsize=18)
    ax.grid(True, linestyle="--", alpha=0.4)
    if ylim_top:
        ax.set_ylim(0, ylim_top)
    ax.set_xlim(left=0)


def fig_etcd():
    s = build_series(ETCD_DIR, "etcd")
    fig, ax = plt.subplots(figsize=(9, 5.5))
    plot_single_panel(ax, s, "etcd — 4 lines, batched (size=16, t=5 ms)",
                      ylim_top=2000)
    ax.legend(loc="upper left", fontsize=14)
    fig.tight_layout()
    out = f"{OUT_DIR}/etcd_full_batched_sweep_2026-05-26.pdf"
    fig.savefig(out, bbox_inches="tight")
    fig.savefig(out.replace(".pdf", ".png"), dpi=200, bbox_inches="tight")
    print(f"wrote {out}")
    plt.close(fig)
    _print_table("etcd batched", s)


def fig_zk():
    s = build_series(ZK_DIR, "zookeeper")
    fig, ax = plt.subplots(figsize=(9, 5.5))
    # ZK has very large p90 at saturation (saw 5.5s at c=100). Auto-scale.
    plot_single_panel(ax, s, "ZooKeeper — 4 lines (pool=2500, maxClientCnxns=3000)",
                      ylim_top=None)
    ax.legend(loc="upper left", fontsize=14)
    fig.tight_layout()
    out = f"{OUT_DIR}/zookeeper_full_sweep_2026-05-26.pdf"
    fig.savefig(out, bbox_inches="tight")
    fig.savefig(out.replace(".pdf", ".png"), dpi=200, bbox_inches="tight")
    print(f"wrote {out}")
    plt.close(fig)
    _print_table("zookeeper", s)


def fig_raft_compare():
    s_on = build_series(RAFT_BATCHON_DIR, "raft")
    s_off = build_series(RAFT_BATCHOFF_DIR, "raft")
    fig, axes = plt.subplots(1, 2, figsize=(15, 5.5), sharey=True)
    plot_single_panel(axes[0], s_on,
                      "Raft — batch ON, pipeline OFF (shipping)", ylim_top=2000)
    plot_single_panel(axes[1], s_off,
                      "Raft — batch OFF, pipeline ON (2026-05-26)", ylim_top=2000)
    axes[1].set_ylabel("")
    axes[0].legend(loc="upper left", fontsize=13)
    fig.tight_layout()
    out = f"{OUT_DIR}/raft_batchon_vs_batchoff_2026-05-26.pdf"
    fig.savefig(out, bbox_inches="tight")
    fig.savefig(out.replace(".pdf", ".png"), dpi=200, bbox_inches="tight")
    print(f"wrote {out}")
    plt.close(fig)
    _print_table("raft batchON+pipeOFF (shipping)", s_on)
    _print_table("raft batchOFF+pipeON (2026-05-26)", s_off)


def _print_table(label, series):
    print(f"\n[{label}]")
    print(f"  {'variant':<10} {'c':>4} {'tput':>8} {'p90':>7}")
    for variant, _p, _m, *_ in VARIANTS:
        for c, t, p in series.get(variant, []):
            print(f"  {variant:<10} {c:>4} {t:>8.0f} {p:>7.0f}")


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    fig_etcd()
    fig_zk()
    fig_raft_compare()
