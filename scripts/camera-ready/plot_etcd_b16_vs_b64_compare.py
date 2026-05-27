#!/usr/bin/env python3
"""etcd batch_size=16 vs batch_size=64 — side-by-side full-grid comparison.

Data:
  LEFT  panel: b=16, max_undone=100 (cluster cap 6 K)  — 2026-05-26
                from log/_etcd_full_batched_sweep_2026-05-26/
  RIGHT panel: b=64, max_undone=300 (cluster cap 18 K) — 2026-05-27
                from log/_etcd_batchsize_64_maxundone300_full_2026-05-27/

Note: the two runs use different max_undone, so the b=16 line is
client-side-capped at ~6 K r/s at c=100+. To see the *pure* batch_size
effect, look at c=1, 50, 100 (where max_undone=100 wasn't binding).
For overall scale + ceiling, look at c=150, 200, 300.
"""
import os, re, statistics
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

LOG = "/home/users/ztang/janus/results/2026-05-13-camera-ready-exp0-fixes-v3/log"
OUT = "/home/users/ztang/janus/results/2026-05-13-camera-ready-exp0-fixes-v3/figs/2026-05-26-full-sweeps"
DIR_B16 = f"{LOG}/_etcd_full_batched_sweep_2026-05-26"
DIR_B64 = f"{LOG}/_etcd_batchsize_64_maxundone300_full_2026-05-27"
CONCS = [1, 50, 100, 150, 200, 300]

VARIANTS = [
    ("vanilla",  "none_etcd",  0,   "#437c17", "^", "-"),
    ("fp0",      "rule_etcd",  0,   "black",   "x", ":"),
    ("adaptive", "rule_etcd", 101,  "#B22222", "o", "-."),
    ("fp100",    "rule_etcd", 100,  "orange",  "*", "--"),
]

def parse_one(p):
    if not os.path.exists(p): return None
    with open(p) as f: text = f.read()
    out = {}
    m = re.search(r"Mid throughput is\s+([\d.]+)", text)
    if m: out["tput"] = float(m.group(1))
    m = re.search(r"Read-mid-10s\s+statistics\s+count\s+(\d+)\s+0pct\s+([-\d.]+)\s+50pct\s+([-\d.]+)\s+90pct\s+([-\d.]+)\s+99pct\s+([-\d.]+)\s+ave\s+([-\d.]+)", text)
    if m: out["p90"] = float(m.group(4))
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

def build(d):
    out = {}
    for variant, proto, mode, *_ in VARIANTS:
        pts = []
        for c in CONCS:
            r = agg(d, proto, mode, c)
            if r: pts.append((c, r[0], r[1]))
        out[variant] = pts
    return out

s_b16 = build(DIR_B16)
s_b64 = build(DIR_B64)

plt.rcParams.update({"text.usetex": False, "font.family": "serif",
                     "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
                     "mathtext.fontset": "stix", "xtick.labelsize": 14, "ytick.labelsize": 14})

def plot_panel(ax, series, title, ylim_top=2500):
    for label, _p, _m, color, marker, ls in VARIANTS:
        pts = series.get(label, [])
        if not pts: continue
        xs = [p[1] for p in pts]; ys = [p[2] for p in pts]
        ax.plot(xs, ys, label=label, color=color, marker=marker, linestyle=ls, linewidth=3, ms=10)
    ax.set_xlabel("Throughput (ops/s)", fontsize=16)
    ax.set_ylabel("Read mid-10s p90 (ms)", fontsize=16)
    ax.set_title(title, fontsize=14)
    ax.grid(True, linestyle="--", alpha=0.4)
    ax.set_ylim(0, ylim_top); ax.set_xlim(left=0)

fig, axes = plt.subplots(1, 2, figsize=(15, 5.8), sharey=True)
plot_panel(axes[0], s_b16, "batch_size=16, max_undone=100 (cap 6 K)")
plot_panel(axes[1], s_b64, "batch_size=64, max_undone=300 (cap 18 K)")
axes[1].set_ylabel("")
axes[0].legend(loc="upper left", fontsize=12)
fig.suptitle("etcd — batched, batch_size=16 vs 64 (full c-axis grid)", fontsize=15)
fig.tight_layout(rect=(0, 0, 1, 0.96))
os.makedirs(OUT, exist_ok=True)
out = f"{OUT}/etcd_b16_vs_b64_2026-05-27.pdf"
fig.savefig(out, bbox_inches="tight")
fig.savefig(out.replace(".pdf", ".png"), dpi=200, bbox_inches="tight")
print(f"wrote {out}")
plt.close(fig)

# Also dump table comparing the two side by side
print(f"\n{'variant':<10} {'c':>4} | {'b16 tput':>9} {'b16 p90':>8} | {'b64 tput':>9} {'b64 p90':>8} | {'Δ tput':>8} {'Δ p90':>8}")
print("-" * 85)
for v, *_ in VARIANTS:
    p16 = dict((c, (t, p)) for c, t, p in s_b16.get(v, []))
    p64 = dict((c, (t, p)) for c, t, p in s_b64.get(v, []))
    for c in CONCS:
        if c not in p16 or c not in p64: continue
        t16, ph16 = p16[c]; t64, ph64 = p64[c]
        dt = 100 * (t64 - t16) / t16
        dp = 100 * (ph64 - ph16) / ph16
        print(f"{v:<10} {c:>4} | {t16:>9.0f} {ph16:>8.0f} | {t64:>9.0f} {ph64:>8.0f} | {dt:>+7.1f}% {dp:>+7.1f}%")
    print()
