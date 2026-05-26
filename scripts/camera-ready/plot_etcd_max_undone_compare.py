#!/usr/bin/env python3
"""etcd batched, two max_undone settings — 2-panel comparison.

Compares the 2026-05-26 morning sweep (max_undone=100, cluster cap 6,000
r/s) against the afternoon retest (max_undone=300, cluster cap 18,000
r/s). All cells use etcd_batch_size=16, timeout_ms=5.

Goal: confirm the 6K plateau in the morning sweep was client-side
backpressure clipping, not the etcd backend ceiling.
"""
import os, re, statistics
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

LOG_TOP = "/home/users/ztang/janus/results/2026-05-13-camera-ready-exp0-fixes-v3/log"
DIR_100 = f"{LOG_TOP}/_etcd_full_batched_sweep_2026-05-26"
DIR_300 = f"{LOG_TOP}/_etcd_batched_maxundone300_2026-05-26"
OUT_DIR = f"/home/users/ztang/janus/results/2026-05-13-camera-ready-exp0-fixes-v3/figs/2026-05-26-full-sweeps"

CONCS = [1, 50, 100, 150, 200, 300]
VARIANTS = [
    ("vanilla",  "none_",  0,   "#437c17", "^", "-"),
    ("fp0",      "rule_",  0,   "black",   "x", ":"),
    ("adaptive", "rule_",  101, "#B22222", "o", "-."),
    ("fp100",    "rule_",  100, "orange",  "*", "--"),
]


def parse_one(path):
    if not os.path.exists(path): return None
    with open(path) as f: text = f.read()
    out = {}
    m = re.search(r"Mid throughput is\s+([\d.]+)", text)
    if m: out["tput"] = float(m.group(1))
    m = re.search(r"Read-mid-10s\s+statistics\s+count\s+(\d+)\s+0pct\s+([-\d.]+)"
                  r"\s+50pct\s+([-\d.]+)\s+90pct\s+([-\d.]+)\s+99pct\s+([-\d.]+)\s+ave\s+([-\d.]+)", text)
    if m:
        out["p50"] = float(m.group(3))
        out["p90"] = float(m.group(4))
        out["p99"] = float(m.group(5))
    return out


def agg(dir_path, proto, mode, conc):
    rows = []
    for i in range(10):
        p = os.path.join(dir_path, f"{proto}-60c1s5r10p-rw_1000000-concurrent_{conc}-{mode}-YCSB_A-server{i}.res")
        d = parse_one(p)
        if d: rows.append(d)
    if not rows: return None
    tputs = [r["tput"] for r in rows if "tput" in r]
    p90s = [r["p90"] for r in rows if "p90" in r]
    if not tputs or not p90s: return None
    return sum(tputs), statistics.median(p90s)


def build_series(dir_path):
    out = {}
    for label, prefix, mode, *_ in VARIANTS:
        proto = f"{prefix}etcd"
        pts = []
        for c in CONCS:
            r = agg(dir_path, proto, mode, c)
            if r is None: continue
            pts.append((c, r[0], r[1]))
        if pts: out[label] = pts
    return out


plt.rcParams.update({"text.usetex": False, "font.family": "serif",
                     "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
                     "mathtext.fontset": "stix", "xtick.labelsize": 16, "ytick.labelsize": 16})
LINE_WIDTH = 3; MARKER_SIZE = 11


def plot_panel(ax, series, title, ylim_top=2000):
    for label, _p, _m, color, marker, ls in VARIANTS:
        pts = series.get(label, [])
        if not pts: continue
        xs = [p[1] for p in pts]; ys = [p[2] for p in pts]
        ax.plot(xs, ys, label=label, color=color, marker=marker, linestyle=ls,
                linewidth=LINE_WIDTH, ms=MARKER_SIZE)
    ax.set_xlabel("Throughput (ops/s)", fontsize=18)
    ax.set_ylabel("Read mid-10s p90 (ms)", fontsize=18)
    ax.set_title(title, fontsize=16)
    ax.grid(True, linestyle="--", alpha=0.4)
    ax.set_ylim(0, ylim_top); ax.set_xlim(left=0)


def _print(label, series):
    print(f"\n[{label}]")
    print(f"  {'variant':<10} {'c':>4} {'tput':>8} {'p90':>7}")
    for v, *_ in VARIANTS:
        for c, t, p in series.get(v, []):
            print(f"  {v:<10} {c:>4} {t:>8.0f} {p:>7.0f}")


s100 = build_series(DIR_100)
s300 = build_series(DIR_300)
_print("max_undone=100 (cap 6000)", s100)
_print("max_undone=300 (cap 18000)", s300)

os.makedirs(OUT_DIR, exist_ok=True)
fig, axes = plt.subplots(1, 2, figsize=(15, 5.5), sharey=True)
plot_panel(axes[0], s100, "etcd batched, max_undone=100 (cluster cap 6 K)", ylim_top=2000)
plot_panel(axes[1], s300, "etcd batched, max_undone=300 (cluster cap 18 K)", ylim_top=2000)
axes[1].set_ylabel("")
axes[0].legend(loc="upper left", fontsize=13)
fig.tight_layout()
out = f"{OUT_DIR}/etcd_max_undone_compare_2026-05-26.pdf"
fig.savefig(out, bbox_inches="tight")
fig.savefig(out.replace(".pdf", ".png"), dpi=200, bbox_inches="tight")
print(f"\nwrote {out}")
