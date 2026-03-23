#!/usr/bin/env python3
"""
Derive fixed concurrency values from experiment 0 results.

For each protocol family, finds the concurrency level that maximizes
total throughput in the original (vanilla) mode. Saves results to:
  - results/fixed_conc.json (machine-readable)
  - <result_dir>/fixed_conc_selection.md (human-readable)

Usage:
    python3 scripts/derive_fixed_conc.py <result_dir>

Example:
    python3 scripts/derive_fixed_conc.py results/2026-03-23-10:26:07-zoo-5machines
"""

import os
import re
import json
import sys
from collections import defaultdict


MAX_RES_FILE_SIZE = 1_000_000  # 1 MB — skip runaway/corrupt files


def parse_mid_throughput(filepath):
    """Extract 'Mid throughput is <value>' from a .res file."""
    try:
        if os.path.getsize(filepath) > MAX_RES_FILE_SIZE:
            return None
        with open(filepath, 'r') as f:
            for line in f:
                m = re.search(r'Mid throughput is ([\d.]+)', line)
                if m:
                    return float(m.group(1))
    except (FileNotFoundError, IOError):
        pass
    return None


def collect_throughputs(result_dir, site="30c1s5r5p-zoo", servers=None):
    """
    Scan result_dir for .res files and compute total throughput per
    (protocol, workload, concurrent, mode, ycsb) tuple.

    Returns:
        dict: {protocol: {concurrent: {mode: total_throughput}}}
    """
    if servers is None:
        servers = [f"zoo{i}" for i in range(5)]

    # Pattern: <protocol>-<site>-<workload>-<concurrent>-<mode>-<ycsb>-<server>.res
    pattern = re.compile(
        r'^(.+?)-' +                    # protocol
        re.escape(site) + r'-' +        # site
        r'(rw_\d+)-' +                  # workload
        r'(concurrent_\d+)-' +          # concurrent
        r'(\d+)-' +                     # mode
        r'(YCSB_[A-Z])-' +             # ycsb
        r'(.+)\.res$'                   # server
    )

    # Accumulate throughputs
    # key = (protocol, workload, concurrent, mode, ycsb)
    throughput_parts = defaultdict(dict)

    for fname in os.listdir(result_dir):
        m = pattern.match(fname)
        if not m:
            continue
        protocol, workload, concurrent, mode, ycsb, server = m.groups()
        if server not in servers:
            continue

        filepath = os.path.join(result_dir, fname)
        tp = parse_mid_throughput(filepath)
        if tp is None:
            continue

        key = (protocol, workload, concurrent, mode, ycsb)
        throughput_parts[key][server] = tp

    # Sum per-server throughputs to get total
    result = defaultdict(lambda: defaultdict(dict))
    for (protocol, workload, concurrent, mode, ycsb), server_tps in throughput_parts.items():
        if len(server_tps) < len(servers):
            # Incomplete — not all servers reported
            continue
        total_tp = sum(server_tps.values())
        result[protocol][concurrent][mode] = total_tp

    return result


def find_max_throughput_conc(protocol_data, mode="0"):
    """
    Given {concurrent: {mode: throughput}}, find the concurrent that
    maximizes throughput for the given mode.

    Returns (best_conc, best_throughput, all_results)
    """
    best_conc = None
    best_tp = -1
    all_results = []

    for conc, mode_data in sorted(protocol_data.items(),
                                   key=lambda x: int(x[0].split('_')[1])):
        tp = mode_data.get(mode, 0)
        all_results.append((conc, tp))
        if tp > best_tp:
            best_tp = tp
            best_conc = conc

    return best_conc, best_tp, all_results


# Protocol families: vanilla protocol name -> display name
PROTOCOL_MAP = {
    "none_raft": "Raft",
    "none_copilot": "Copilot",
    "none_mencius": "Mencius",
    "none_mongodb": "MongoDB",
    "none_etcd": "etcd",
    "none_zookeeper": "ZooKeeper",
}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    result_dir = sys.argv[1]
    if not os.path.isdir(result_dir):
        print(f"Error: {result_dir} is not a directory")
        sys.exit(1)

    print(f"Scanning {result_dir}...")
    data = collect_throughputs(result_dir)

    if not data:
        print("No valid results found. Is the experiment still running?")
        sys.exit(1)

    # Find fixed conc for each protocol
    fixed_conc = {}
    selection_details = []

    for vanilla_proto, display_name in PROTOCOL_MAP.items():
        if vanilla_proto not in data:
            print(f"  {display_name}: no data yet (skipping)")
            continue

        best_conc, best_tp, all_results = find_max_throughput_conc(
            data[vanilla_proto], mode="0"
        )

        if best_conc is None:
            print(f"  {display_name}: no mode=0 (original) data")
            continue

        # Also record rule_ version
        rule_proto = vanilla_proto.replace("none_", "rule_")
        fixed_conc[vanilla_proto] = best_conc
        fixed_conc[rule_proto] = best_conc
        fixed_conc[display_name] = best_conc

        detail = {
            "protocol": display_name,
            "vanilla_key": vanilla_proto,
            "fixed_conc": best_conc,
            "max_throughput": round(best_tp, 2),
            "all_concs": [(c, round(t, 2)) for c, t in all_results],
        }
        selection_details.append(detail)

        print(f"  {display_name}: {best_conc} (throughput={best_tp:.2f})")

    if not fixed_conc:
        print("No fixed concurrencies could be derived. Experiment may still be running.")
        sys.exit(1)

    # Save machine-readable JSON
    json_path = os.path.join(os.path.dirname(result_dir) if "/" in result_dir else ".",
                              "results", "fixed_conc.json")
    # If result_dir is already under results/, save alongside it
    if "results/" in result_dir or "results\\" in result_dir:
        json_path = os.path.join(os.path.dirname(result_dir), "fixed_conc.json")

    os.makedirs(os.path.dirname(json_path), exist_ok=True)
    with open(json_path, 'w') as f:
        json.dump(fixed_conc, f, indent=2)
    print(f"\nSaved: {json_path}")

    # Save human-readable markdown in the result folder
    md_path = os.path.join(result_dir, "fixed_conc_selection.md")
    with open(md_path, 'w') as f:
        f.write("# Fixed Concurrency Selection\n\n")
        f.write("Derived from experiment 0 (throughput-latency sweep).\n")
        f.write("For each protocol, the concurrency level that maximizes\n")
        f.write("total throughput in the original (vanilla, mode=0) mode.\n\n")

        f.write("## Selection\n\n")
        f.write("| Protocol   | Fixed Concurrency | Max Throughput (txn/s) |\n")
        f.write("|------------|-------------------|-----------------------|\n")
        for d in selection_details:
            f.write(f"| {d['protocol']:<10} | {d['fixed_conc']:<17} | {d['max_throughput']:>21.2f} |\n")

        f.write("\n## Per-Protocol Sweep Data\n\n")
        for d in selection_details:
            f.write(f"### {d['protocol']} ({d['vanilla_key']})\n\n")
            f.write(f"Selected: **{d['fixed_conc']}** (throughput={d['max_throughput']} txn/s)\n\n")
            f.write("| Concurrency | Throughput (txn/s) |\n")
            f.write("|-------------|--------------------|\n")
            for conc, tp in d['all_concs']:
                marker = " **<--**" if conc == d['fixed_conc'] else ""
                f.write(f"| {conc:<11} | {tp:>18.2f} |{marker}\n")
            f.write("\n")

    print(f"Saved: {md_path}")


if __name__ == "__main__":
    main()
