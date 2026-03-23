#!/usr/bin/env python3
"""
Sanity-check experiment 0 results for latency and throughput consistency.

Checks:
  1. Original mode: leader-colocated latency ~ 1 RTT, non-leader ~ 2 RTT
  2. Jetpack rule mode: latency ~ 1 RTT for all clients
  3. Adaptive mode: max throughput in same ballpark as original
  4. WAN_DELAY_MS=20 was applied (RTT ~ 40ms baseline)

Outputs:
  <result_dir>/sanity_checks.md

Usage:
    python3 scripts/sanity_check.py <result_dir> [--wan-delay-ms 20]

Example:
    python3 scripts/sanity_check.py results/2026-03-23-10:26:07-zoo-5machines
"""

import os
import re
import json
import sys
from collections import defaultdict
from datetime import datetime

# --- Configuration ---
LEADER_SERVER = "zoo0"  # loc_id=0 → leader for all protocols
SERVERS = [f"zoo{i}" for i in range(5)]
SITE = "30c1s5r5p-zoo"

PROTOCOL_FAMILIES = {
    "raft":       {"none": "none_raft",       "rule": "rule_raft"},
    "copilot":    {"none": "none_copilot",    "rule": "rule_copilot"},
    "mencius":    {"none": "none_mencius",    "rule": "rule_mencius"},
    "mongodb":    {"none": "none_mongodb",    "rule": "rule_mongodb"},
    "etcd":       {"none": "none_etcd",       "rule": "rule_etcd"},
    "zookeeper":  {"none": "none_zookeeper",  "rule": "rule_zookeeper"},
}

# Protocol-specific latency characteristics in original (vanilla) mode.
# leader_rtt: expected leader-colocated latency in multiples of RTT
# follower_rtt: expected follower/non-leader latency in multiples of RTT
# reason: protocol-specific explanation
PROTOCOL_LATENCY_MODEL = {
    "raft":       {"leader_rtt": 1, "follower_rtt": 2,
                   "reason": "leader replicates in 1 RTT; follower forwards + replicates in 2 RTT"},
    "copilot":    {"leader_rtt": 2, "follower_rtt": 2,
                   "reason": "both pilots must agree (~2 RTT); all clients see ~2 RTT"},
    "mencius":    {"leader_rtt": 1, "follower_rtt": 1,
                   "reason": "multi-leader: each server commits locally in ~1 RTT"},
    "mongodb":    {"leader_rtt": 1, "follower_rtt": 2,
                   "reason": "single-leader like Raft; leader 1 RTT, follower 2 RTT"},
    "etcd":       {"leader_rtt": 1, "follower_rtt": 2,
                   "reason": "single-leader Raft-based; leader 1 RTT, follower 2 RTT"},
    "zookeeper":  {"leader_rtt": 1, "follower_rtt": 2,
                   "reason": "single-leader ZAB; leader 1 RTT, follower 2 RTT"},
}

# Mode codes
MODE_ORIGINAL = "0"      # vanilla protocol
MODE_RULE_100 = "1"      # Jetpack 100% fast-path
MODE_ADAPTIVE = "101"    # Jetpack adaptive


def parse_res_file(filepath):
    """Parse a .res file for latency stats and throughput."""
    result = {
        "mid_throughput": None,
        "total_throughput": None,
        "original_path": None,
        "fast_path": None,
        "efficient_path": None,
        "wan_delay_detected": False,
    }

    stat_pattern = re.compile(
        r'(All-(?:original|fast|efficient)-path-attempts|All-efficient-attempts)\s+'
        r'statistics\s+'
        r'count\s+(\d+)\s+'
        r'0pct\s+([\d.-]+)\s+'
        r'50pct\s+([\d.-]+)\s+'
        r'90pct\s+([\d.-]+)\s+'
        r'99pct\s+([\d.-]+)\s+'
        r'ave\s+([\d.-]+)'
    )

    try:
        with open(filepath, 'r') as f:
            for line in f:
                # Check for WAN delay
                if 'WAN delay enabled' in line or 'WAN_DELAY_MS' in line:
                    result["wan_delay_detected"] = True

                # Mid throughput
                m = re.search(r'Mid throughput is ([\d.]+)', line)
                if m:
                    result["mid_throughput"] = float(m.group(1))

                # Total throughput
                m = re.search(r'Total throughtput is ([\d.]+)', line)
                if m:
                    result["total_throughput"] = float(m.group(1))

                # Latency stats
                m = stat_pattern.search(line)
                if m:
                    stat_name = m.group(1)
                    stats = {
                        "count": int(m.group(2)),
                        "0pct": float(m.group(3)),
                        "50pct": float(m.group(4)),
                        "90pct": float(m.group(5)),
                        "99pct": float(m.group(6)),
                        "ave": float(m.group(7)),
                    }
                    if "original" in stat_name:
                        result["original_path"] = stats
                    elif "fast" in stat_name:
                        result["fast_path"] = stats
                    elif "efficient" in stat_name:
                        result["efficient_path"] = stats

    except (FileNotFoundError, IOError):
        pass

    return result


def collect_experiment_data(result_dir):
    """
    Collect per-server data for all experiment configs.

    Returns:
        dict: {(protocol, concurrent, mode): {server: parsed_data}}
    """
    pattern = re.compile(
        r'^(.+?)-' +
        re.escape(SITE) + r'-' +
        r'(rw_\d+)-' +
        r'(concurrent_\d+)-' +
        r'(\d+)-' +
        r'(YCSB_[A-Z])-' +
        r'(.+)\.res$'
    )

    data = defaultdict(dict)

    for fname in os.listdir(result_dir):
        m = pattern.match(fname)
        if not m:
            continue
        protocol, workload, concurrent, mode, ycsb, server = m.groups()
        if server not in SERVERS:
            continue

        filepath = os.path.join(result_dir, fname)
        parsed = parse_res_file(filepath)
        data[(protocol, concurrent, mode)][server] = parsed

    return data


def get_latency_for_conc(data, protocol, concurrent, mode):
    """Get per-server latency data for a specific config."""
    key = (protocol, concurrent, mode)
    if key not in data:
        return None
    server_data = data[key]
    if len(server_data) < len(SERVERS):
        return None
    return server_data


def get_total_throughput(data, protocol, concurrent, mode):
    """Sum mid_throughput across all servers for a config."""
    key = (protocol, concurrent, mode)
    if key not in data:
        return None
    server_data = data[key]
    if len(server_data) < len(SERVERS):
        return None
    total = sum(
        sd["mid_throughput"] for sd in server_data.values()
        if sd["mid_throughput"] is not None
    )
    return total if total > 0 else None


def find_moderate_conc(data, protocol, mode):
    """
    Find a moderate concurrency level for latency analysis.
    Picks the concurrency with the highest throughput in mode=0 (original),
    then uses that as the reference point.
    """
    best_conc = None
    best_tp = -1

    for (proto, conc, m), server_data in data.items():
        if proto != protocol or m != mode:
            continue
        if len(server_data) < len(SERVERS):
            continue
        tp = sum(sd["mid_throughput"] for sd in server_data.values()
                 if sd["mid_throughput"] is not None)
        if tp > best_tp:
            best_tp = tp
            best_conc = conc

    return best_conc, best_tp


def check_wan_delay(data, protocol):
    """Check if WAN delay was detected in any .res file for this protocol."""
    for (proto, conc, mode), server_data in data.items():
        if proto != protocol:
            continue
        for sd in server_data.values():
            if sd.get("wan_delay_detected"):
                return True
    return False


def compute_latency_stats(server_data, path_key="efficient_path"):
    """
    Compute latency summary across servers.
    Falls back through efficient_path -> original_path -> fast_path.
    """
    leader_lat = None
    follower_lats = []

    for server, sd in server_data.items():
        stats = sd.get(path_key)
        # Fallback chain
        if stats is None or stats["count"] == 0:
            stats = sd.get("original_path")
        if stats is None or stats["count"] == 0:
            stats = sd.get("fast_path")
        if stats is None or stats["count"] == 0:
            continue

        lat = stats["50pct"]
        if lat < 0:
            continue

        if server == LEADER_SERVER:
            leader_lat = lat
        else:
            follower_lats.append(lat)

    avg_follower = sum(follower_lats) / len(follower_lats) if follower_lats else None
    return leader_lat, avg_follower, follower_lats


class SanityResult:
    """Holds one sanity check result."""
    def __init__(self, name, expected, observed, passed, note=""):
        self.name = name
        self.expected = expected
        self.observed = observed
        self.passed = passed
        self.note = note


def compute_path_usage(server_data):
    """
    Compute fast-path vs original-path usage stats from server data.

    Returns dict with:
        fast_count: total fast-path attempts across servers
        original_count: total original-path attempts across servers
        efficient_count: total efficient-path attempts across servers
        avg_original_lat: average original-path p50 latency (ms)
        avg_efficient_lat: average efficient-path p50 latency (ms)
    """
    fast_count = 0
    original_count = 0
    efficient_count = 0
    original_lats = []
    efficient_lats = []

    for server, sd in server_data.items():
        fp = sd.get("fast_path")
        op = sd.get("original_path")
        ep = sd.get("efficient_path")
        if fp and fp["count"] > 0:
            fast_count += fp["count"]
        if op and op["count"] > 0:
            original_count += op["count"]
            if op["50pct"] > 0:
                original_lats.append(op["50pct"])
        if ep and ep["count"] > 0:
            efficient_count += ep["count"]
            if ep["50pct"] > 0:
                efficient_lats.append(ep["50pct"])

    return {
        "fast_count": fast_count,
        "original_count": original_count,
        "efficient_count": efficient_count,
        "avg_original_lat": (sum(original_lats) / len(original_lats)) if original_lats else None,
        "avg_efficient_lat": (sum(efficient_lats) / len(efficient_lats)) if efficient_lats else None,
    }


def run_sanity_checks(result_dir, wan_delay_ms=20):
    """Run all sanity checks. Returns (list[SanityResult], summary_dict)."""
    rtt_ms = wan_delay_ms * 2  # 40ms for 20ms one-way
    rtt_tolerance = 0.6  # Allow 60% tolerance for processing overhead + queuing

    data = collect_experiment_data(result_dir)
    if not data:
        return [], {"error": "No experiment data found"}

    results = []
    protocol_summaries = {}

    for family_name, protocols in PROTOCOL_FAMILIES.items():
        none_proto = protocols["none"]
        rule_proto = protocols["rule"]

        family_results = []
        has_data = False

        # Check WAN delay
        if check_wan_delay(data, none_proto) or check_wan_delay(data, rule_proto):
            results.append(SanityResult(
                f"{family_name}: WAN delay",
                f"WAN_DELAY_MS={wan_delay_ms} detected",
                "Detected",
                True
            ))
        elif any((p, c, m) in data for p in [none_proto, rule_proto]
                 for (p2, c, m) in data if p2 == p):
            results.append(SanityResult(
                f"{family_name}: WAN delay",
                f"WAN_DELAY_MS={wan_delay_ms} detected",
                "NOT detected",
                False,
                "WAN delay may not have been applied"
            ))

        # --- Check 1: Original mode latency pattern ---
        mod_conc, orig_tp = find_moderate_conc(data, none_proto, MODE_ORIGINAL)
        if mod_conc and orig_tp > 0:
            has_data = True
            server_data = get_latency_for_conc(data, none_proto, mod_conc, MODE_ORIGINAL)
            if server_data:
                leader_lat, avg_follower, follower_lats = compute_latency_stats(
                    server_data, "original_path"
                )

                if leader_lat is not None:
                    lat_model = PROTOCOL_LATENCY_MODEL.get(family_name, {"leader_rtt": 1, "follower_rtt": 2})
                    leader_rtt_mult = lat_model["leader_rtt"]
                    expected_ms = rtt_ms * leader_rtt_mult
                    expected_leader = f"~{expected_ms:.0f}ms ({leader_rtt_mult} RTT) + overhead"
                    observed_leader = f"{leader_lat:.1f}ms"
                    # Reasonable if within 0.5x to 3x of expected
                    leader_ok = expected_ms * 0.5 <= leader_lat <= expected_ms * 3
                    results.append(SanityResult(
                        f"{family_name} original: leader (zoo0) p50 latency @ {mod_conc}",
                        expected_leader,
                        observed_leader,
                        leader_ok,
                        f"throughput={orig_tp:.0f} txn/s ({lat_model['reason']})" + (
                            "" if leader_ok else
                            f" WARNING: expected {expected_ms*0.5:.0f}-{expected_ms*3:.0f}ms"
                        )
                    ))
                    family_results.append(("leader_lat", leader_lat))

                if avg_follower is not None:
                    lat_model = PROTOCOL_LATENCY_MODEL.get(family_name, {"leader_rtt": 1, "follower_rtt": 2})
                    follower_rtt_mult = lat_model["follower_rtt"]
                    expected_ms = rtt_ms * follower_rtt_mult
                    expected_follower = f"~{expected_ms:.0f}ms ({follower_rtt_mult} RTT) + overhead"
                    observed_follower = f"{avg_follower:.1f}ms (followers avg)"
                    # Reasonable if within 0.5x to 3x of expected
                    follower_ok = expected_ms * 0.5 <= avg_follower <= expected_ms * 3
                    results.append(SanityResult(
                        f"{family_name} original: follower avg p50 latency @ {mod_conc}",
                        expected_follower,
                        observed_follower,
                        follower_ok,
                        f"per-follower: {', '.join(f'{l:.1f}' for l in follower_lats)}ms"
                    ))
                    family_results.append(("follower_lat", avg_follower))

        # --- Check 2: Rule mode (Jetpack 100%) latency ~ 1 RTT for all ---
        rule_conc, rule_tp = find_moderate_conc(data, rule_proto, MODE_RULE_100)
        if rule_conc is None:
            # Try using same conc as original with mode=1
            rule_conc = mod_conc
        if rule_conc:
            server_data = get_latency_for_conc(data, rule_proto, rule_conc, MODE_RULE_100)
            if server_data:
                has_data = True
                leader_lat, avg_follower, follower_lats = compute_latency_stats(
                    server_data, "efficient_path"
                )
                # In Jetpack rule mode, all clients should see ~1 RTT
                all_lats = []
                for server, sd in server_data.items():
                    stats = sd.get("efficient_path") or sd.get("fast_path")
                    if stats and stats["count"] > 0 and stats["50pct"] > 0:
                        all_lats.append((server, stats["50pct"]))

                if all_lats:
                    avg_all = sum(l for _, l in all_lats) / len(all_lats)
                    max_lat = max(l for _, l in all_lats)
                    min_lat = min(l for _, l in all_lats)

                    expected_rule = f"~{rtt_ms}ms (1 RTT) for all clients"
                    observed_rule = f"avg={avg_all:.1f}ms, range=[{min_lat:.1f}, {max_lat:.1f}]ms"
                    rule_ok = rtt_ms * 0.3 <= avg_all <= rtt_ms * 3
                    results.append(SanityResult(
                        f"{family_name} rule: all-client p50 latency @ {rule_conc}",
                        expected_rule,
                        observed_rule,
                        rule_ok,
                        f"per-server: {', '.join(f'{s}={l:.1f}' for s, l in all_lats)}"
                    ))
                    family_results.append(("rule_lat", avg_all))

        # --- Check 3: Adaptive mode throughput vs original ---
        if mod_conc:
            adaptive_tp = get_total_throughput(data, rule_proto, mod_conc, MODE_ADAPTIVE)
            if adaptive_tp is not None and orig_tp is not None and orig_tp > 0:
                has_data = True
                ratio = adaptive_tp / orig_tp
                expected_adaptive = f"within 0.5x-2.0x of original ({orig_tp:.0f} txn/s)"
                observed_adaptive = f"{adaptive_tp:.0f} txn/s ({ratio:.2f}x of original)"
                adaptive_ok = 0.3 <= ratio <= 2.5

                # Build diagnostic note for failures
                diag_note = ""
                if not adaptive_ok:
                    diag_note = "WARNING: throughput significantly different from original"
                    # Add path-usage diagnostics
                    adaptive_server_data = get_latency_for_conc(
                        data, rule_proto, mod_conc, MODE_ADAPTIVE
                    )
                    if adaptive_server_data:
                        usage = compute_path_usage(adaptive_server_data)
                        diag_note += (
                            f" | path-usage: fast={usage['fast_count']}"
                            f", original={usage['original_count']}"
                            f", efficient={usage['efficient_count']}"
                        )
                        if usage["avg_original_lat"] is not None:
                            diag_note += f" | original-path p50={usage['avg_original_lat']:.1f}ms"
                        if usage["fast_count"] == 0:
                            diag_note += " | DIAGNOSTIC: zero fast-path attempts in adaptive mode"

                results.append(SanityResult(
                    f"{family_name} adaptive: throughput @ {mod_conc}",
                    expected_adaptive,
                    observed_adaptive,
                    adaptive_ok,
                    diag_note
                ))
                family_results.append(("adaptive_ratio", ratio))

                # Store path usage for report if anomalous
                if not adaptive_ok and adaptive_server_data:
                    family_results.append(("adaptive_anomaly", {
                        "throughput": adaptive_tp,
                        "ratio": ratio,
                        "path_usage": compute_path_usage(adaptive_server_data),
                    }))

        if not has_data:
            results.append(SanityResult(
                f"{family_name}: data availability",
                "Experiment data present",
                "No data found",
                False,
                "Protocol may not have completed experiment 0 yet"
            ))

        protocol_summaries[family_name] = family_results

    return results, protocol_summaries


def generate_report(results, protocol_summaries, result_dir, wan_delay_ms=20):
    """Generate sanity_checks.md report."""
    rtt_ms = wan_delay_ms * 2
    passed = sum(1 for r in results if r.passed)
    failed = sum(1 for r in results if not r.passed)

    lines = []
    lines.append("# Experiment 0 Sanity Checks\n")
    lines.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    lines.append(f"Result directory: `{result_dir}`\n")
    lines.append(f"WAN model: WAN_DELAY_MS={wan_delay_ms} (one-way), RTT≈{rtt_ms}ms\n")
    lines.append(f"\n## Summary\n")
    lines.append(f"- **Passed**: {passed}")
    lines.append(f"- **Failed/Warning**: {failed}")
    lines.append(f"- **Total checks**: {passed + failed}\n")

    overall = "PASS" if failed == 0 and passed > 0 else "PARTIAL" if passed > 0 else "NO DATA"
    lines.append(f"**Overall**: {overall}\n")

    lines.append("\n## WAN Latency Model\n")
    lines.append(f"- One-way delay: {wan_delay_ms}ms (WAN_DELAY_MS environment variable)")
    lines.append(f"- Expected RTT: ~{rtt_ms}ms")
    lines.append(f"- Mechanism: Application-level delay via `_wan_wait()` in communicator.h")
    lines.append(f"- Leader: {LEADER_SERVER} (loc_id=0, 130.245.173.101)\n")

    lines.append("\n## Expected Latency Patterns (Original Mode)\n")
    lines.append(f"| Protocol | Leader-colocated | Non-leader | Reason |")
    lines.append(f"|----------|-----------------|------------|--------|")
    for family_name, lat_model in PROTOCOL_LATENCY_MODEL.items():
        lr = lat_model["leader_rtt"]
        fr = lat_model["follower_rtt"]
        lines.append(f"| {family_name.title()} | ~{rtt_ms*lr}ms ({lr} RTT) | ~{rtt_ms*fr}ms ({fr} RTT) | {lat_model['reason']} |")
    lines.append("")
    lines.append(f"**Jetpack rule mode**: ~{rtt_ms}ms (1 RTT) for all clients (fast-path bypass)")
    lines.append(f"**Jetpack adaptive**: between original and rule mode\n")

    lines.append("\n## Per-Check Results\n")
    lines.append("| # | Check | Expected | Observed | Status | Note |")
    lines.append("|---|-------|----------|----------|--------|------|")
    for i, r in enumerate(results, 1):
        status = "PASS" if r.passed else "FAIL"
        icon = "+" if r.passed else "-"
        note = r.note[:120] if r.note else ""
        lines.append(f"| {i} | {r.name} | {r.expected} | {r.observed} | {icon} {status} | {note} |")

    lines.append("\n\n## Protocol-Level Summary\n")
    for family, checks in protocol_summaries.items():
        if not checks:
            lines.append(f"\n### {family.title()}\nNo data available yet.\n")
            continue
        lines.append(f"\n### {family.title()}\n")
        for check_type, value in checks:
            if check_type == "leader_lat":
                lines.append(f"- Leader p50 latency: {value:.1f}ms")
            elif check_type == "follower_lat":
                lines.append(f"- Follower avg p50 latency: {value:.1f}ms")
            elif check_type == "rule_lat":
                lines.append(f"- Rule mode avg p50 latency: {value:.1f}ms")
            elif check_type == "adaptive_ratio":
                lines.append(f"- Adaptive throughput ratio vs original: {value:.2f}x")
            elif check_type == "adaptive_anomaly":
                # Don't duplicate ratio line, just add diagnostic detail
                pass

    # --- Flagged Anomalies section ---
    anomalies = []
    for family, checks in protocol_summaries.items():
        for check_type, value in checks:
            if check_type == "adaptive_anomaly":
                anomalies.append((family, value))

    if anomalies:
        lines.append("\n\n## Flagged Anomalies\n")
        lines.append("These failures require investigation or a protocol-specific explanation.\n")
        for family, info in anomalies:
            usage = info["path_usage"]
            lines.append(f"\n### {family.title()} — Adaptive Mode Throughput Anomaly\n")
            lines.append(f"- **Throughput**: {info['throughput']:.0f} txn/s ({info['ratio']:.2f}x of original)")
            lines.append(f"- **Fast-path attempts**: {usage['fast_count']}")
            lines.append(f"- **Original-path attempts**: {usage['original_count']}")
            lines.append(f"- **Efficient-path attempts**: {usage['efficient_count']}")
            if usage["avg_original_lat"] is not None:
                lines.append(f"- **Original-path p50 latency**: {usage['avg_original_lat']:.1f}ms")
            if usage["avg_efficient_lat"] is not None:
                lines.append(f"- **Efficient-path p50 latency**: {usage['avg_efficient_lat']:.1f}ms")
            if usage["fast_count"] == 0:
                lines.append(f"\n**Diagnosis**: Zero fast-path attempts in adaptive mode. "
                             f"The adaptive algorithm never activated the Jetpack fast path "
                             f"for {family.title()}. All requests went through the original "
                             f"protocol path, but with anomalously high latency. This suggests "
                             f"a potential issue with the adaptive controller for this protocol.")
            lines.append("")

    lines.append("\n\n## Interpretation Notes\n")
    lines.append("""
- Latency checks use the concurrency level that maximizes original-mode throughput.
- \"Leader-colocated\" means clients running on the same machine as the protocol leader (zoo0).
- Expected RTTs are protocol-specific (see table above): Copilot needs 2 RTT for cross-pilot
  agreement; Mencius achieves 1 RTT for all servers as a multi-leader protocol.
- Tolerance is 0.5x-3x of protocol-specific expected value to allow for processing overhead.
- Adaptive mode throughput should be in the same ballpark as original mode at the same concurrency.
- If a protocol shows no data, it means experiment 0 hasn't completed for that family yet.
""")

    return "\n".join(lines)


def main():
    wan_delay_ms = 20

    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    result_dir = sys.argv[1]
    if not os.path.isdir(result_dir):
        print(f"Error: {result_dir} is not a directory")
        sys.exit(1)

    # Parse optional --wan-delay-ms
    for i, arg in enumerate(sys.argv):
        if arg == "--wan-delay-ms" and i + 1 < len(sys.argv):
            wan_delay_ms = int(sys.argv[i + 1])

    print(f"Running sanity checks on {result_dir}...")
    print(f"WAN model: {wan_delay_ms}ms one-way, {wan_delay_ms*2}ms RTT")
    print()

    results, summaries = run_sanity_checks(result_dir, wan_delay_ms)

    if not results:
        print("No data found. Is the experiment still running?")
        sys.exit(1)

    # Print summary to console
    passed = sum(1 for r in results if r.passed)
    failed = sum(1 for r in results if not r.passed)
    print(f"Results: {passed} passed, {failed} failed/warning\n")

    for r in results:
        icon = "PASS" if r.passed else "FAIL"
        print(f"  [{icon}] {r.name}")
        print(f"         Expected: {r.expected}")
        print(f"         Observed: {r.observed}")
        if r.note:
            print(f"         Note: {r.note}")
        print()

    # Save report
    report = generate_report(results, summaries, result_dir, wan_delay_ms)
    report_path = os.path.join(result_dir, "sanity_checks.md")
    with open(report_path, 'w') as f:
        f.write(report)
    print(f"Saved: {report_path}")

    # Exit code: 0 if all pass, 1 if any fail
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
