#!/usr/bin/env python3
"""
Generate SUMMARY.md for a Zoo experiment result directory.

Scans the result directory for .res files and produces a summary report
covering experiment configuration, progress, per-protocol status, and
links to related artifacts (sanity_checks.md, fixed_conc_selection.md,
LATENCY_MECHANISM.md).

Re-runnable: can be called at any time to update SUMMARY.md with the
latest progress.

Usage:
    python3 scripts/generate_summary.py <result_dir>

Example:
    python3 scripts/generate_summary.py results/2026-03-23-10:26:07-zoo-5machines
"""

import os
import re
import sys
import json
import subprocess
from collections import defaultdict
from datetime import datetime


SITE = "30c1s5r5p-zoo"
SERVERS = [f"zoo{i}" for i in range(5)]
MAX_RES_FILE_SIZE = 1_000_000  # 1 MB — skip runaway/corrupt files
ZOO_HOSTS = [
    "130.245.173.101",
    "130.245.173.102",
    "130.245.173.103",
    "130.245.173.104",
    "130.245.173.105",
]

PROTOCOL_FAMILIES = [
    ("Raft",       "none_raft",       "rule_raft"),
    ("Copilot",    "none_copilot",    "rule_copilot"),
    ("Mencius",    "none_mencius",    "rule_mencius"),
    ("MongoDB",    "none_mongodb",    "rule_mongodb"),
    ("etcd",       "none_etcd",       "rule_etcd"),
    ("ZooKeeper",  "none_zookeeper",  "rule_zookeeper"),
]

# Expected experiment matrix per protocol family for experiment 0 (mode=0)
# Each protocol has a different set of concurrency levels
MODE_NAMES = {
    "0": "original (vanilla)",
    "1": "Jetpack 100%",
    "100": "Jetpack 0%",
    "101": "Jetpack adaptive",
}


def get_git_info():
    """Get current git commit hash and branch."""
    try:
        commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], stderr=subprocess.DEVNULL
        ).decode().strip()
        branch = subprocess.check_output(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"], stderr=subprocess.DEVNULL
        ).decode().strip()
        return commit, branch
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown", "unknown"


def parse_mid_throughput(filepath):
    """Extract throughput from a .res file.

    Prefers 'Mid throughput' (steady-state). Falls back to 'Total throughtput'
    when Mid is unavailable (e.g. shorter MongoDB runs).
    """
    mid_tp = None
    total_tp = None
    try:
        if os.path.getsize(filepath) > MAX_RES_FILE_SIZE:
            return None
        with open(filepath, 'r') as f:
            for line in f:
                if mid_tp is None:
                    m = re.search(r'Mid throughput is ([\d.]+)', line)
                    if m:
                        mid_tp = float(m.group(1))
                if total_tp is None:
                    m2 = re.search(r'Total throughtput is ([\d.]+)', line)
                    if m2:
                        total_tp = float(m2.group(1))
    except (FileNotFoundError, IOError):
        pass
    return mid_tp if mid_tp is not None else total_tp


def scan_results(result_dir):
    """
    Scan result directory and categorize experiments.

    Returns:
        dict with keys:
        - experiments: {(protocol, conc, mode): {server: throughput}}
        - protocols: set of protocols found
        - modes: set of modes found
        - total_configs: number of unique (protocol, conc, mode) tuples
        - complete_configs: configs with all 5 servers
    """
    pattern = re.compile(
        r'^(.+?)-' +
        re.escape(SITE) + r'-' +
        r'(rw_[\w.]+)-' +
        r'(concurrent_\d+)-' +
        r'(\d+)-' +
        r'(YCSB_[A-Z])-' +
        r'(.+)\.res$'
    )

    experiments = defaultdict(dict)
    all_res_files = 0

    for fname in os.listdir(result_dir):
        if not fname.endswith('.res'):
            continue
        all_res_files += 1
        m = pattern.match(fname)
        if not m:
            continue
        protocol, workload, conc, mode, ycsb, server = m.groups()
        if server not in SERVERS:
            continue

        filepath = os.path.join(result_dir, fname)
        tp = parse_mid_throughput(filepath)
        experiments[(protocol, workload, conc, mode, ycsb)][server] = tp

    protocols = set()
    modes = set()
    complete = 0
    for key, server_data in experiments.items():
        protocols.add(key[0])
        modes.add(key[3])
        if len(server_data) >= len(SERVERS):
            complete += 1

    return {
        "experiments": experiments,
        "protocols": protocols,
        "modes": modes,
        "total_configs": len(experiments),
        "complete_configs": complete,
        "total_res_files": all_res_files,
    }


def get_protocol_status(scan, family_name, none_proto, rule_proto):
    """Get per-protocol experiment status."""
    status = {
        "name": family_name,
        "none_proto": none_proto,
        "rule_proto": rule_proto,
        "mode0_concs": 0,
        "mode1_concs": 0,
        "mode100_concs": 0,
        "mode101_concs": 0,
        "total_complete": 0,
        "max_throughput": 0,
        "best_conc": None,
    }

    for (proto, workload, conc, mode, ycsb), server_data in scan["experiments"].items():
        if proto not in (none_proto, rule_proto):
            continue
        if len(server_data) < len(SERVERS):
            continue

        status["total_complete"] += 1
        tp = sum(v for v in server_data.values() if v is not None)

        if mode == "0":
            status["mode0_concs"] += 1
            if tp > status["max_throughput"]:
                status["max_throughput"] = tp
                status["best_conc"] = conc
        elif mode == "1":
            status["mode1_concs"] += 1
        elif mode == "100":
            status["mode100_concs"] += 1
        elif mode == "101":
            status["mode101_concs"] += 1

    return status


def check_artifact(result_dir, filename):
    """Check if an artifact exists in the result directory."""
    path = os.path.join(result_dir, filename)
    if os.path.isfile(path):
        size = os.path.getsize(path)
        return True, f"{size} bytes"
    return False, "missing"


def generate_summary(result_dir):
    """Generate SUMMARY.md content."""
    commit, branch = get_git_info()
    scan = scan_results(result_dir)
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # Extract timestamp from directory name
    dir_name = os.path.basename(result_dir)

    lines = []
    lines.append("# Zoo 5-Machine Experiment Summary\n")
    lines.append(f"**Generated**: {now}")
    lines.append(f"**Result directory**: `{result_dir}`")
    lines.append(f"**Directory name**: `{dir_name}`")
    lines.append(f"**Git commit**: `{commit[:12]}`")
    lines.append(f"**Git branch**: `{branch}`\n")

    # --- Configuration ---
    lines.append("## Configuration\n")
    lines.append(f"| Parameter | Value |")
    lines.append(f"|-----------|-------|")
    lines.append(f"| Site config | `{SITE}` |")
    lines.append(f"| Servers | {len(SERVERS)} ({', '.join(SERVERS)}) |")
    lines.append(f"| Zoo hosts | {', '.join(ZOO_HOSTS)} |")
    lines.append(f"| WAN latency | 20ms one-way (WAN_DELAY_MS=20), RTT ~40ms |")
    lines.append(f"| Latency mechanism | Application-level delay via `_wan_wait()` |")
    lines.append(f"| Protocol families | {len(PROTOCOL_FAMILIES)} |")
    lines.append(f"| Benchmark type | Open-loop |")
    lines.append(f"| YCSB workload | YCSB_A (50% read, 50% write) |\n")

    # --- Progress ---
    lines.append("## Progress\n")
    lines.append(f"| Metric | Value |")
    lines.append(f"|--------|-------|")
    lines.append(f"| Total .res files | {scan['total_res_files']} |")
    lines.append(f"| Unique experiment configs | {scan['total_configs']} |")
    lines.append(f"| Complete configs (all {len(SERVERS)} servers) | {scan['complete_configs']} |")
    lines.append(f"| Protocols with data | {', '.join(sorted(scan['protocols'])) if scan['protocols'] else 'none'} |")
    lines.append(f"| Modes with data | {', '.join(sorted(scan['modes'])) if scan['modes'] else 'none'} |\n")

    # --- Per-Protocol Status ---
    lines.append("## Per-Protocol Status\n")
    lines.append(f"| Protocol | Mode 0 (original) | Mode 1 (rule) | Mode 100 (0%) | Mode 101 (adaptive) | Total | Peak Throughput |")
    lines.append(f"|----------|-------------------|---------------|---------------|---------------------|-------|-----------------|")

    for family_name, none_proto, rule_proto in PROTOCOL_FAMILIES:
        st = get_protocol_status(scan, family_name, none_proto, rule_proto)
        peak = f"{st['max_throughput']:.0f} txn/s @ {st['best_conc']}" if st['best_conc'] else "—"
        lines.append(
            f"| {family_name:<10} | {st['mode0_concs']:>17} | {st['mode1_concs']:>13} | "
            f"{st['mode100_concs']:>13} | {st['mode101_concs']:>19} | {st['total_complete']:>5} | {peak} |"
        )

    lines.append("")

    # --- Experiment Definitions ---
    lines.append("## Experiment Definitions\n")
    lines.append("### Experiment 0: Throughput-Latency Sweep")
    lines.append("- Workload: `rw_1000000`")
    lines.append("- YCSB: `YCSB_A`")
    lines.append("- Modes: original (0), Jetpack 0% (100), Jetpack 100% (1), Jetpack adaptive (101)")
    lines.append("- Per-protocol concurrency sweep\n")

    lines.append("### Experiment 1: Zipfian-Skew Sweep (pending)")
    lines.append("- Workloads: `rw_zipf_{1,0.9,0.8,0.7,0.6,0.5}`")
    lines.append("- Fixed concurrency per protocol (derived from experiment 0)\n")

    lines.append("### Experiment 2: Key-Range Sweep (pending)")
    lines.append("- Workloads: `rw_{1,10,100,1000,10000,100000,1000000}`")
    lines.append("- Fixed concurrency per protocol (derived from experiment 0)\n")

    # --- Artifacts ---
    lines.append("## Artifacts\n")
    artifacts = [
        ("sanity_checks.md", "Latency/throughput sanity check results"),
        ("fixed_conc_selection.md", "Fixed concurrency derivation"),
        ("LATENCY_MECHANISM.md", "WAN latency injection documentation"),
    ]

    lines.append("| Artifact | Status | Description |")
    lines.append("|----------|--------|-------------|")
    lines.append("| `SUMMARY.md` | present (this file) | Experiment summary |")
    for fname, desc in artifacts:
        exists, info = check_artifact(result_dir, fname)
        status = f"present ({info})" if exists else "**missing**"
        lines.append(f"| `{fname}` | {status} | {desc} |")

    # Check for figs/ and tables/ directories
    figs_dir = os.path.join(result_dir, "figs")
    tables_dir = os.path.join(result_dir, "tables")
    figs_count = len(os.listdir(figs_dir)) if os.path.isdir(figs_dir) else 0
    tables_count = len(os.listdir(tables_dir)) if os.path.isdir(tables_dir) else 0
    lines.append(f"| `figs/` | {figs_count} files | Exported figure PDFs |")
    lines.append(f"| `tables/` | {tables_count} files | Exported data tables |")

    # Check fixed_conc.json in parent
    fc_path = os.path.join(os.path.dirname(result_dir), "fixed_conc.json")
    if os.path.isfile(fc_path):
        try:
            with open(fc_path) as f:
                fc_data = json.load(f)
            fc_info = f"present ({len(fc_data)} entries)"
        except (json.JSONDecodeError, IOError):
            fc_info = "present (parse error)"
    else:
        fc_info = "**missing**"
    lines.append(f"| `../fixed_conc.json` | {fc_info} | Machine-readable fixed concurrencies |")

    lines.append("")

    # --- Notes ---
    lines.append("## Notes\n")
    lines.append("- This summary is auto-generated by `scripts/generate_summary.py`.")
    lines.append("- Re-run at any time to update with latest progress.")
    lines.append("- Sanity checks can be regenerated with `python3 scripts/sanity_check.py <result_dir>`.")
    lines.append("- Fixed concurrencies derived with `python3 scripts/derive_fixed_conc.py <result_dir>`.")
    lines.append("")

    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    result_dir = sys.argv[1]
    if not os.path.isdir(result_dir):
        print(f"Error: {result_dir} is not a directory")
        sys.exit(1)

    summary = generate_summary(result_dir)

    output_path = os.path.join(result_dir, "SUMMARY.md")
    with open(output_path, 'w') as f:
        f.write(summary)

    print(f"Generated: {output_path}")
    print(f"  (re-run to update with latest progress)")


if __name__ == "__main__":
    main()
