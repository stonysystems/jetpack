#!/usr/bin/env python3
"""etcd batch_size sweep at c=200/300, vanilla vs adaptive.

Sources: log/_etcd_batchsize_{4,16,32,64,128}_maxundone300_2026-05-26/
All cells use max_undone=300, etcd_batch_timeout_ms=5.

Goal: find batch_size that maximizes throughput / minimizes p90, and
see whether the vanilla-vs-adaptive ordering depends on batch_size.
"""
import os, re, statistics
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

LOG = "/home/users/ztang/janus/results/2026-05-13-camera-ready-exp0-fixes-v3/log"
OUT_DIR = "/home/users/ztang/janus/results/2026-05-13-camera-ready-exp0-fixes-v3/figs/2026-05-26-full-sweeps"
BATCH_SIZES = [4, 16, 32, 64, 128]
CONCS = [200, 300]
VARIANTS = [
    ("vanilla",  "none_etcd",  0,   "#437c17", "^", "-"),
    ("adaptive", "rule_etcd", 101,  "#B22222", "o", "-."),
]

def parse_one(p):
    if not os.path.exists(p): return None
    with open(p) as f: text = f.read()
    out = {}
    m = re.search(r"Mid throughput is\s+([\d.]+)", text)
    if m: out["tput"] = float(m.group(1))
    m = re.search(r"Read-mid-10s\s+statistics\s+count\s+(\d+)\s+0pct\s+([-\d.]+)\s+50pct\s+([-\d.]+)\s+90pct\s+([-\d.]+)\s+99pct\s+([-\d.]+)\s+ave\s+([-\d.]+)", text)
    if m:
        out["p50"] = float(m.group(3)); out["p90"] = float(m.group(4)); out["p99"] = float(m.group(5))
    return out

def agg(d, proto, mode, c):
    rows = []
    for i in range(10):
        x = parse_one(f"{d}/{proto}-60c1s5r10p-rw_1000000-concurrent_{c}-{mode}-YCSB_A-server{i}.res")
        if x: rows.append(x)
    if not rows: return None
    tputs = [r["tput"] for r in rows if "tput" in r]
    p90s = [r["p90"] for r in rows if "p90" in r]
    if not tputs or not p90s: return None
    return sum(tputs), statistics.median(p90s)

# Build data: data[variant][conc] = [(b, tput, p90), ...]
data = {v[0]: {c: [] for c in CONCS} for v in VARIANTS}
for b in BATCH_SIZES:
    d = f"{LOG}/_etcd_batchsize_{b}_maxundone300_2026-05-26"
    for variant, proto, mode, *_ in VARIANTS:
        for c in CONCS:
            r = agg(d, proto, mode, c)
            if r:
                data[variant][c].append((b, r[0], r[1]))

# Print table
print(f"\n{'variant':<10} {'c':>4} {'b':>4} | {'tput':>6} | {'R p90':>7}")
print("-" * 45)
for v in ("vanilla", "adaptive"):
    for c in CONCS:
        for b, t, p in data[v][c]:
            print(f"{v:<10} {c:>4} {b:>4} | {t:>6.0f} | {p:>7.0f}")
        print()

# Plot: 2 panels (tput, p90), x=batch_size (log), 4 lines (variant × conc)
plt.rcParams.update({"text.usetex": False, "font.family": "serif",
                     "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
                     "mathtext.fontset": "stix", "xtick.labelsize": 14, "ytick.labelsize": 14})
fig, axes = plt.subplots(1, 2, figsize=(14, 5.5))

CONC_STYLE = {200: ("-", "o"), 300: ("--", "s")}
VARIANT_COLOR = {"vanilla": "#437c17", "adaptive": "#B22222"}

for ax, (metric_idx, ylab) in zip(axes, [(1, "Cluster throughput (ops/s)"), (2, "Read mid-10s p90 (ms)")]):
    for v in ("vanilla", "adaptive"):
        for c in CONCS:
            pts = data[v][c]
            if not pts: continue
            xs = [p[0] for p in pts]; ys = [p[metric_idx] for p in pts]
            ls, marker = CONC_STYLE[c]
            ax.plot(xs, ys, color=VARIANT_COLOR[v], linestyle=ls, marker=marker,
                    linewidth=3, ms=11, label=f"{v} c={c}")
    ax.set_xscale("log", base=2)
    ax.set_xticks(BATCH_SIZES); ax.set_xticklabels(BATCH_SIZES)
    ax.set_xlabel("etcd_batch_size", fontsize=16)
    ax.set_ylabel(ylab, fontsize=16)
    ax.grid(True, linestyle="--", alpha=0.4)
    ax.legend(loc="best", fontsize=11)

fig.suptitle("etcd batched, max_undone=300 — batch_size sweep @ c=200, 300", fontsize=16)
fig.tight_layout(rect=(0, 0, 1, 0.96))
os.makedirs(OUT_DIR, exist_ok=True)
out = f"{OUT_DIR}/etcd_batchsize_sweep_2026-05-26.pdf"
fig.savefig(out, bbox_inches="tight")
fig.savefig(out.replace(".pdf", ".png"), dpi=200, bbox_inches="tight")
print(f"\nwrote {out}")
