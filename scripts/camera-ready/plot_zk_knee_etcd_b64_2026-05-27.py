#!/usr/bin/env python3
"""Two figures from the 2026-05-27 session:
   (1) ZK with dense knee sampling (c=1, 50, 60, 70, 80, 90, 100, 150, 200, 300)
   (2) etcd full grid at batch_size=64 + max_undone=300
"""
import os, re, statistics
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

LOG = "/home/users/ztang/janus/results/2026-05-13-camera-ready-exp0-fixes-v3/log"
OUT = "/home/users/ztang/janus/results/2026-05-13-camera-ready-exp0-fixes-v3/figs/2026-05-26-full-sweeps"

# ZK: combine prior full sweep (c=1, 50, 100, 150, 200, 300) with knee-add (c=60, 70, 80, 90)
ZK_DIRS = [
    (f"{LOG}/_zookeeper_full_sweep_2026-05-26", [1, 50, 100, 150, 200, 300]),
    (f"{LOG}/_zookeeper_knee_sweep_2026-05-27", [60, 70, 80, 90]),
]
ETCD_DIR = f"{LOG}/_etcd_batchsize_64_maxundone300_full_2026-05-27"
ETCD_CONCS = [1, 50, 100, 150, 200, 300]

VARIANTS = [
    ("vanilla",  "none_",  0,   "#437c17", "^", "-"),
    ("fp0",      "rule_",  0,   "black",   "x", ":"),
    ("adaptive", "rule_",  101, "#B22222", "o", "-."),
    ("fp100",    "rule_",  100, "orange",  "*", "--"),
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

def build_zk_series():
    out = {}
    for variant, prefix, mode, *_ in VARIANTS:
        proto = f"{prefix}zookeeper"
        pts = []
        for d, concs in ZK_DIRS:
            for c in concs:
                r = agg(d, proto, mode, c)
                if r: pts.append((c, r[0], r[1]))
        pts.sort(key=lambda x: x[0])
        out[variant] = pts
    return out

def build_etcd_series():
    out = {}
    for variant, prefix, mode, *_ in VARIANTS:
        proto = f"{prefix}etcd"
        pts = []
        for c in ETCD_CONCS:
            r = agg(ETCD_DIR, proto, mode, c)
            if r: pts.append((c, r[0], r[1]))
        out[variant] = pts
    return out

plt.rcParams.update({"text.usetex": False, "font.family": "serif",
                     "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
                     "mathtext.fontset": "stix", "xtick.labelsize": 14, "ytick.labelsize": 14})

# Figure 1: ZK with knee detail (tput vs p90)
zk_s = build_zk_series()
fig, ax = plt.subplots(figsize=(9, 5.5))
for label, _p, _m, color, marker, ls in VARIANTS:
    pts = zk_s.get(label, [])
    if not pts: continue
    xs = [p[1] for p in pts]; ys = [p[2] for p in pts]
    ax.plot(xs, ys, label=label, color=color, marker=marker, linestyle=ls, linewidth=3, ms=10)
    # annotate the knee region
    for c, x, y in pts:
        if c in (50, 60, 70, 80, 90, 100):
            ax.annotate(f"c={c}", (x, y), textcoords="offset points", xytext=(5, 4), fontsize=8, color=color)
ax.set_xlabel("Throughput (ops/s)", fontsize=16)
ax.set_ylabel("Read mid-10s p90 (ms)", fontsize=16)
ax.set_title("ZK — dense knee sampling (c=50..100 step 10)", fontsize=15)
ax.grid(True, linestyle="--", alpha=0.4)
ax.legend(loc="upper left", fontsize=12)
fig.tight_layout()
os.makedirs(OUT, exist_ok=True)
out = f"{OUT}/zk_knee_dense_2026-05-27.pdf"
fig.savefig(out, bbox_inches="tight")
fig.savefig(out.replace(".pdf", ".png"), dpi=200, bbox_inches="tight")
print(f"wrote {out}")
plt.close(fig)

print("\n[ZK]")
print(f"{'variant':<10} {'c':>4} {'tput':>6} {'p90':>7}")
for v, *_ in VARIANTS:
    for c, t, p in zk_s.get(v, []):
        print(f"{v:<10} {c:>4} {t:>6.0f} {p:>7.0f}")
    print()

# Figure 2: etcd full grid at b=64
etcd_s = build_etcd_series()
fig, ax = plt.subplots(figsize=(9, 5.5))
for label, _p, _m, color, marker, ls in VARIANTS:
    pts = etcd_s.get(label, [])
    if not pts: continue
    xs = [p[1] for p in pts]; ys = [p[2] for p in pts]
    ax.plot(xs, ys, label=label, color=color, marker=marker, linestyle=ls, linewidth=3, ms=10)
ax.set_xlabel("Throughput (ops/s)", fontsize=16)
ax.set_ylabel("Read mid-10s p90 (ms)", fontsize=16)
ax.set_title("etcd — batch_size=64, max_undone=300", fontsize=15)
ax.grid(True, linestyle="--", alpha=0.4)
ax.legend(loc="upper left", fontsize=12)
fig.tight_layout()
out = f"{OUT}/etcd_b64_full_2026-05-27.pdf"
fig.savefig(out, bbox_inches="tight")
fig.savefig(out.replace(".pdf", ".png"), dpi=200, bbox_inches="tight")
print(f"\nwrote {out}")
plt.close(fig)

print("\n[etcd b=64]")
print(f"{'variant':<10} {'c':>4} {'tput':>6} {'p90':>7}")
for v, *_ in VARIANTS:
    for c, t, p in etcd_s.get(v, []):
        print(f"{v:<10} {c:>4} {t:>6.0f} {p:>7.0f}")
    print()
