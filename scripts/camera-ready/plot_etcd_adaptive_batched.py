#!/usr/bin/env python3
"""etcd panel: adaptive batched vs baseline at 5 concurrencies.

Shows that client-side Txn batching (size=16, timeout=5ms) closes the
cpprestsdk pplx surge for rule_etcd m=101 (adaptive). Companion to the
2026-05-26 smoke + sweep.

Baselines:
  - Adaptive (pre-batched) at c={50,75,150,200}: pre-Fix-4 archive
    (2026-05-08, older code, only complete adaptive sweep available).
    c=100 baseline is from post-Fix-1 (2026-05-19) — clean.
  - Vanilla (pre-batched) c=100 reference dot from post-Fix-1.
  - Vanilla batched c=100 reference dot from today's smoke.

The script reads .res files using the standard parser shape — same as
gen_tput_p90_figures.py — and reports mid-10s Read p90.
"""
import os, re, statistics
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

LOG = "/home/users/ztang/janus/results/2026-05-13-camera-ready-exp0-fixes-v3/log"
ARCH_FIX1 = LOG + "/_etcd_fix1_2026-05-19"
ARCH_PRE_F4 = LOG + "/_etcd_pre_fix4_2026-05-08"
ARCH_BATCH = LOG + "/_etcd_adaptive_batch_sweep_2026-05-26"
ARCH_VAN_BATCH = LOG + "/_etcd_batch_smoke_2026-05-26"

CONCS = [50, 75, 100, 150, 200]


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
        out["p90"] = float(m.group(4))
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


def adaptive_baseline_for(c):
    """Pre-batched adaptive baseline. c=100 uses post-Fix-1; others use pre-Fix-4."""
    if c == 100:
        return agg(ARCH_FIX1, "rule_etcd", 101, c)
    return agg(ARCH_PRE_F4, "rule_etcd", 101, c)


# Build curves
baseline_pts = []  # adaptive pre-batched
batched_pts = []   # adaptive batched
for c in CONCS:
    b = adaptive_baseline_for(c)
    if b:
        baseline_pts.append((c, b[0], b[1]))
    t = agg(ARCH_BATCH, "rule_etcd", 101, c)
    if t:
        batched_pts.append((c, t[0], t[1]))

# Reference points at c=100
ref_van_pre = agg(ARCH_FIX1, "none_etcd", 0, 100)
ref_van_batched = agg(ARCH_VAN_BATCH, "none_etcd", 0, 100)

# Plot
plt.rcParams.update(
    {
        "text.usetex": False,
        "font.family": "serif",
        "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
        "mathtext.fontset": "stix",
        "xtick.labelsize": 16,
        "ytick.labelsize": 16,
    }
)
LINE_WIDTH = 3
MARKER_SIZE = 12

fig, ax = plt.subplots(figsize=(8, 5.5))

if baseline_pts:
    xs = [p[1] for p in baseline_pts]
    ys = [p[2] for p in baseline_pts]
    ax.plot(
        xs, ys, "o-.", color="#B22222", linewidth=LINE_WIDTH,
        ms=MARKER_SIZE, label="adaptive — pre-batched",
    )
    for c, x, y in baseline_pts:
        ax.annotate(f"c={c}", (x, y), textcoords="offset points",
                    xytext=(7, -3), fontsize=11, color="#B22222")

if batched_pts:
    xs = [p[1] for p in batched_pts]
    ys = [p[2] for p in batched_pts]
    ax.plot(
        xs, ys, "s-", color="#1f6f8b", linewidth=LINE_WIDTH,
        ms=MARKER_SIZE, label="adaptive — batched (size=16)",
    )
    for c, x, y in batched_pts:
        ax.annotate(f"c={c}", (x, y), textcoords="offset points",
                    xytext=(7, 6), fontsize=11, color="#1f6f8b")

# Reference dots at c=100
if ref_van_pre:
    ax.plot([ref_van_pre[0]], [ref_van_pre[1]], "^", color="#437c17",
            ms=MARKER_SIZE + 2, label="vanilla c=100 — pre-batched")
if ref_van_batched:
    ax.plot([ref_van_batched[0]], [ref_van_batched[1]], "v", color="#2c8d3c",
            ms=MARKER_SIZE + 2, label="vanilla c=100 — batched")

ax.set_xlabel("Throughput (ops/s)", fontsize=18)
ax.set_ylabel("Read mid-10s p90 latency (ms)", fontsize=18)
ax.set_title("etcd adaptive (m=101): batching closes the cpprestsdk surge",
             fontsize=16)
ax.grid(True, linestyle="--", alpha=0.4)
ax.set_ylim(0, max(p[2] for p in baseline_pts) * 1.1 if baseline_pts else 2000)
ax.set_xlim(left=0)
ax.legend(loc="upper left", fontsize=12)

fig.tight_layout()
out_pdf = (
    "/home/users/ztang/janus/results/2026-05-13-camera-ready-exp0-fixes-v3/"
    "figs/etcd_adaptive_batched_2026-05-26.pdf"
)
out_png = out_pdf.replace(".pdf", ".png")
fig.savefig(out_pdf, bbox_inches="tight")
fig.savefig(out_png, dpi=200, bbox_inches="tight")
print(f"wrote {out_pdf}")
print(f"wrote {out_png}")

print(f"\nData table:")
print(f"{'curve':<28} {'c':>4} {'tput':>8} {'p90 (ms)':>10}")
print("-" * 56)
for c, t, p in baseline_pts:
    print(f"{'adaptive pre-batched':<28} {c:>4} {t:>8.0f} {p:>10.0f}")
for c, t, p in batched_pts:
    print(f"{'adaptive batched':<28} {c:>4} {t:>8.0f} {p:>10.0f}")
if ref_van_pre:
    print(f"{'vanilla pre-batched':<28} {100:>4} {ref_van_pre[0]:>8.0f} {ref_van_pre[1]:>10.0f}")
if ref_van_batched:
    print(f"{'vanilla batched':<28} {100:>4} {ref_van_batched[0]:>8.0f} {ref_van_batched[1]:>10.0f}")
