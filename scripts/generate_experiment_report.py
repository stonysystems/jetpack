#!/usr/bin/env python3
"""
Generate EXPERIMENT_REPORT.md in a Zoo result directory.

This produces a concise experiment report that ties together:
- Per-protocol throughput/latency summaries from .res files
- References to sanity checks, fixed-conc selection, figures, tables
- Experiment progress and status per protocol family

Usage:
    python3 scripts/generate_experiment_report.py <result_dir>

The report is saved as <result_dir>/EXPERIMENT_REPORT.md.
"""

import os
import re
import sys
import json
import glob
from datetime import datetime
from collections import defaultdict


SITE = "30c1s5r5p-zoo"
SERVERS = [f"zoo{i}" for i in range(5)]
PROTOCOL_FAMILIES = {
    "raft": ("none_raft", "rule_raft"),
    "copilot": ("none_copilot", "rule_copilot"),
    "mencius": ("none_mencius", "rule_mencius"),
    "mongodb": ("none_mongodb", "rule_mongodb"),
    "etcd": ("none_etcd", "rule_etcd"),
    "zookeeper": ("none_zookeeper", "rule_zookeeper"),
}
MODE_LABELS = {"0": "Original", "1": "Jetpack 100%", "100": "Jetpack 0%", "101": "Adaptive"}


def parse_res_file(path):
    """Extract key metrics from a .res file."""
    metrics = {}
    try:
        with open(path) as f:
            for line in f:
                if "Mid throughput is" in line:
                    m = re.search(r"Mid throughput is ([\d.]+)", line)
                    if m:
                        metrics["throughput"] = float(m.group(1))
                if "All-original-path-attempts" in line and "statistics" in line:
                    m = re.search(
                        r"count\s+(\d+)\s+0pct\s+([\d.-]+)\s+50pct\s+([\d.-]+)\s+"
                        r"90pct\s+([\d.-]+)\s+99pct\s+([\d.-]+)\s+ave\s+([\d.-]+)",
                        line,
                    )
                    if m:
                        metrics["count"] = int(m.group(1))
                        metrics["p50"] = float(m.group(3))
                        metrics["p90"] = float(m.group(4))
                        metrics["p99"] = float(m.group(5))
                        metrics["ave"] = float(m.group(6))
    except (OSError, IOError):
        pass
    return metrics


def collect_data(result_dir):
    """Collect per-protocol, per-mode, per-concurrency aggregated data."""
    data = defaultdict(lambda: defaultdict(lambda: defaultdict(dict)))
    pattern = re.compile(
        r"^(.+?)-" + re.escape(SITE) + r"-rw_(\d+)-concurrent_(\d+)-(\d+)-YCSB_A-(.+)\.res$"
    )
    for fname in os.listdir(result_dir):
        m = pattern.match(fname)
        if not m:
            continue
        protocol, workload, conc_num, mode, server = m.groups()
        conc_key = f"concurrent_{conc_num}"
        path = os.path.join(result_dir, fname)
        metrics = parse_res_file(path)
        if not metrics:
            continue

        key = (protocol, mode, conc_key)
        if key not in data:
            data[key] = {"servers": {}, "workload": workload}
        data[key]["servers"][server] = metrics

    # Aggregate: sum throughput, average latencies across servers
    results = {}
    for (protocol, mode, conc_key), info in data.items():
        servers = info["servers"]
        if len(servers) < len(SERVERS):
            continue  # incomplete
        total_tp = sum(s.get("throughput", 0) for s in servers.values())
        avg_p50 = sum(s.get("p50", 0) for s in servers.values()) / len(servers)
        avg_p90 = sum(s.get("p90", 0) for s in servers.values()) / len(servers)
        avg_p99 = sum(s.get("p99", 0) for s in servers.values()) / len(servers)
        avg_ave = sum(s.get("ave", 0) for s in servers.values()) / len(servers)

        if protocol not in results:
            results[protocol] = {}
        if mode not in results[protocol]:
            results[protocol][mode] = {}
        results[protocol][mode][conc_key] = {
            "throughput": total_tp,
            "p50": avg_p50,
            "p90": avg_p90,
            "p99": avg_p99,
            "ave": avg_ave,
        }
    return results


def find_peak(mode_data):
    """Find peak throughput concurrency for a mode's data."""
    best_conc = None
    best_tp = 0
    for conc, metrics in mode_data.items():
        if metrics["throughput"] > best_tp:
            best_tp = metrics["throughput"]
            best_conc = conc
    return best_conc, best_tp


def check_artifact(result_dir, name):
    """Check if an artifact exists and return its info."""
    path = os.path.join(result_dir, name)
    if os.path.isfile(path):
        size = os.path.getsize(path)
        return f"present ({size} bytes)"
    elif os.path.isdir(path):
        count = len([f for f in os.listdir(path) if not f.startswith(".")])
        return f"present ({count} files)"
    return "missing"


def count_pdfs(result_dir):
    """Count PDF files in figs directory."""
    figs_dir = os.path.join(result_dir, "figs")
    if not os.path.isdir(figs_dir):
        return 0
    return len(glob.glob(os.path.join(figs_dir, "*.pdf")))


def load_fixed_conc(result_dir):
    """Load fixed_conc.json if available."""
    # Check result_dir parent (results/) for fixed_conc.json
    parent = os.path.dirname(result_dir)
    path = os.path.join(parent, "fixed_conc.json")
    if os.path.isfile(path):
        with open(path) as f:
            return json.load(f)
    return {}


def generate_report(result_dir):
    """Generate the full experiment report."""
    data = collect_data(result_dir)
    fixed_conc = load_fixed_conc(result_dir)
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    lines = []
    lines.append("# Zoo 5-Machine Experiment Report")
    lines.append("")
    lines.append(f"**Generated**: {now}")
    lines.append(f"**Result directory**: `{result_dir}`")
    lines.append("")

    # Experiment status
    lines.append("## Experiment Status")
    lines.append("")
    total_res = len([f for f in os.listdir(result_dir) if f.endswith(".res")])
    protocols_with_data = sorted(set(p for p in data.keys()))
    families_with_data = set()
    for p in protocols_with_data:
        for fam, (vanilla, jetpack) in PROTOCOL_FAMILIES.items():
            if p in (vanilla, jetpack):
                families_with_data.add(fam)
    lines.append(f"- **Total .res files**: {total_res}")
    lines.append(f"- **Protocols with data**: {', '.join(protocols_with_data) if protocols_with_data else 'none'}")
    lines.append(f"- **Protocol families with data**: {len(families_with_data)} of 6 ({', '.join(sorted(families_with_data)) if families_with_data else 'none'})")
    lines.append("")

    # Per-family detail
    lines.append("## Per-Protocol Family Results")
    lines.append("")

    for fam_name, (vanilla_proto, jetpack_proto) in PROTOCOL_FAMILIES.items():
        fam_display = fam_name.capitalize()
        vanilla_data = data.get(vanilla_proto, {})
        jetpack_data = data.get(jetpack_proto, {})

        if not vanilla_data and not jetpack_data:
            lines.append(f"### {fam_display}")
            lines.append("")
            lines.append("No data available yet.")
            lines.append("")
            continue

        lines.append(f"### {fam_display}")
        lines.append("")

        # Original mode (mode 0) — peak throughput
        mode0 = vanilla_data.get("0", {})
        if mode0:
            peak_conc, peak_tp = find_peak(mode0)
            if peak_conc:
                peak_metrics = mode0[peak_conc]
                lines.append(f"**Original mode (vanilla, mode 0)**:")
                lines.append(f"- Peak throughput: **{peak_tp:.0f} txn/s** @ {peak_conc}")
                lines.append(f"- At peak: p50={peak_metrics['p50']:.1f}ms, p90={peak_metrics['p90']:.1f}ms, p99={peak_metrics['p99']:.1f}ms, avg={peak_metrics['ave']:.1f}ms")
                lines.append("")

        # Jetpack adaptive (mode 101)
        mode101_vanilla = vanilla_data.get("101", {})
        if mode101_vanilla:
            peak_conc, peak_tp = find_peak(mode101_vanilla)
            if peak_conc:
                peak_metrics = mode101_vanilla[peak_conc]
                lines.append(f"**Adaptive mode (mode 101)**:")
                lines.append(f"- Peak throughput: **{peak_tp:.0f} txn/s** @ {peak_conc}")
                lines.append(f"- At peak: p50={peak_metrics['p50']:.1f}ms, p90={peak_metrics['p90']:.1f}ms, p99={peak_metrics['p99']:.1f}ms, avg={peak_metrics['ave']:.1f}ms")
                lines.append("")

        # Jetpack 0% (mode 100)
        mode100_vanilla = vanilla_data.get("100", {})
        if mode100_vanilla:
            peak_conc, peak_tp = find_peak(mode100_vanilla)
            if peak_conc:
                peak_metrics = mode100_vanilla[peak_conc]
                lines.append(f"**Jetpack 0% mode (mode 100)**:")
                lines.append(f"- Peak throughput: **{peak_tp:.0f} txn/s** @ {peak_conc}")
                lines.append(f"- At peak: p50={peak_metrics['p50']:.1f}ms, p90={peak_metrics['p90']:.1f}ms, p99={peak_metrics['p99']:.1f}ms, avg={peak_metrics['ave']:.1f}ms")
                lines.append("")

        # Fixed concurrency
        fc_key = f"none_{fam_name}" if fam_name != "raft" else "none_raft"
        fc_entry = fixed_conc.get(fc_key)
        if fc_entry:
            # fixed_conc.json may store just the concurrency string or a dict
            if isinstance(fc_entry, dict):
                fc_conc = fc_entry.get("concurrency", "?")
                fc_tp = fc_entry.get("throughput", "?")
            else:
                fc_conc = str(fc_entry)
                # Look up throughput from data
                fc_tp = mode0.get(fc_conc, {}).get("throughput", "?") if mode0 else "?"
            fc_tp_str = f"{fc_tp:.1f}" if isinstance(fc_tp, (int, float)) else str(fc_tp)
            lines.append(f"**Fixed concurrency**: {fc_conc} (throughput {fc_tp_str} txn/s)")
            lines.append("")

        # Mode comparison table at fixed concurrency
        if fc_entry and mode0:
            if isinstance(fc_entry, dict):
                fc_conc = fc_entry.get("concurrency", "")
            else:
                fc_conc = str(fc_entry)
            table_modes = []
            for mode_code, label in [("0", "Original"), ("100", "Jetpack 0%"), ("101", "Adaptive")]:
                mode_data_src = vanilla_data.get(mode_code, {})
                if fc_conc in mode_data_src:
                    m = mode_data_src[fc_conc]
                    table_modes.append((label, m))

            if table_modes:
                lines.append(f"**Comparison at {fc_conc}**:")
                lines.append("")
                lines.append("| Mode | Throughput | p50 (ms) | p90 (ms) | p99 (ms) | avg (ms) |")
                lines.append("|------|-----------|----------|----------|----------|----------|")
                for label, m in table_modes:
                    lines.append(
                        f"| {label} | {m['throughput']:.0f} | {m['p50']:.1f} | {m['p90']:.1f} | {m['p99']:.1f} | {m['ave']:.1f} |"
                    )
                lines.append("")

    # Artifacts inventory
    lines.append("## Artifacts")
    lines.append("")
    artifacts = [
        ("EXPERIMENT_REPORT.md", "This report"),
        ("SUMMARY.md", "Auto-generated progress summary"),
        ("sanity_checks.md", "Latency/throughput sanity check"),
        ("fixed_conc_selection.md", "Fixed concurrency derivation"),
        ("LATENCY_MECHANISM.md", "WAN latency injection documentation"),
        ("evaluation_executed.ipynb", "Executed analysis notebook"),
        ("figs/", "Exported figure PDFs"),
        ("tables/", "Exported data tables"),
    ]
    lines.append("| Artifact | Status |")
    lines.append("|----------|--------|")
    for name, desc in artifacts:
        status = check_artifact(result_dir, name)
        lines.append(f"| `{name}` | {status} — {desc} |")
    lines.append("")

    # Fixed-conc summary
    if fixed_conc:
        lines.append("## Fixed Concurrency Map")
        lines.append("")
        lines.append("| Protocol | Concurrency |")
        lines.append("|----------|-------------|")
        for proto, info in sorted(fixed_conc.items()):
            conc_val = info if isinstance(info, str) else info.get("concurrency", "?")
            lines.append(f"| {proto} | {conc_val} |")
        lines.append("")

    # References
    lines.append("## References")
    lines.append("")
    lines.append("- Sanity checks: see `sanity_checks.md` in this folder")
    lines.append("- Fixed concurrency derivation: see `fixed_conc_selection.md` in this folder")
    lines.append("- WAN latency mechanism: see `LATENCY_MECHANISM.md` in this folder")
    lines.append("- Progress tracking: see `SUMMARY.md` in this folder")
    lines.append("- Full analysis: see `evaluation_executed.ipynb` in this folder")
    lines.append("- Pipeline: `scripts/run_evaluation.sh`")
    lines.append("")
    lines.append("---")
    lines.append(f"*Auto-generated by `scripts/generate_experiment_report.py` on {now}*")
    lines.append("")

    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 generate_experiment_report.py <result_dir>")
        sys.exit(1)

    result_dir = sys.argv[1]
    if not os.path.isdir(result_dir):
        print(f"Error: {result_dir} is not a directory")
        sys.exit(1)

    report = generate_report(result_dir)
    output_path = os.path.join(result_dir, "EXPERIMENT_REPORT.md")
    with open(output_path, "w") as f:
        f.write(report)
    print(f"Generated: {output_path}")


if __name__ == "__main__":
    main()
