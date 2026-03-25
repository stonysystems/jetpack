#!/usr/bin/env python3
"""
Audit CSV completeness for a Zoo experiment result directory.

For each experiment prefix, checks whether all 5 expected CSV files are
present and classifies incomplete prefixes by root cause:
  - scp_pull_gap:   server dumped CSV (Dumped to line present) but file missing locally
  - crash_abort:    server crashed (cannot bind, FATAL, generic server error)
  - never_dumped:   server ran but never reached CSV dump (no Dumped to line, no crash)
  - timeout:        server appears to have been killed mid-run (no statistics, no dump)
  - zero_throughput: server ran but produced zero throughput
  - other:          none of the above

Outputs:
  - <result_dir>/csv_audit.json  — machine-readable audit report

Usage:
    python3 scripts/csv_audit.py <result_dir> [--servers zoo0,zoo1,zoo2,zoo3,zoo4]
"""

import json
import os
import re
import sys
from collections import defaultdict


DEFAULT_SERVERS = [f"zoo{i}" for i in range(5)]

# Signals to look for in .res files
CRASH_PATTERNS = [
    re.compile(r"cannot bind to"),
    re.compile(r"generic server error"),
    re.compile(r"^F \["),           # FATAL log lines
    re.compile(r"Segmentation fault"),
    re.compile(r"core dumped"),
    re.compile(r"SIGABRT"),
    re.compile(r"double free"),
]

DUMP_PATTERN = re.compile(r"Dumped to .+\.csv with (\d+) lines")
THROUGHPUT_PATTERN = re.compile(r"Mid throughput is ([\d.]+)")
STATISTICS_PATTERN = re.compile(r"All-efficient-attempts\s+statistics\s+count\s+(\d+)")
SHUTDOWN_PATTERN = re.compile(r"server_shutdown")


# Maximum bytes to read from each end of a .res file for classification.
# Summary lines (statistics, dump, throughput) are near the end; crash
# signals can appear anywhere but early crashes show up near the start.
_READ_HEAD_BYTES = 64 * 1024   # 64 KB from start
_READ_TAIL_BYTES = 64 * 1024   # 64 KB from end


def _read_head_tail(filepath, head_bytes=_READ_HEAD_BYTES, tail_bytes=_READ_TAIL_BYTES):
    """Read the first and last N bytes of a file, avoiding full reads of huge files."""
    file_size = os.path.getsize(filepath)
    with open(filepath, 'rb') as f:
        head = f.read(min(head_bytes, file_size))
        if file_size <= head_bytes + tail_bytes:
            # File small enough to have been fully read
            tail = head[max(0, len(head) - tail_bytes):]
        else:
            f.seek(-tail_bytes, 2)
            tail = f.read(tail_bytes)
    return (head.decode('utf-8', errors='replace'),
            tail.decode('utf-8', errors='replace'),
            file_size)


def classify_server(res_path, has_csv):
    """Classify a single server's status for one experiment prefix.

    Returns dict with:
      has_csv: bool
      has_res: bool
      classification: str  (one of the categories above, or 'complete')
      evidence: str        (key signal from .res file)
    """
    result = {
        "has_csv": has_csv,
        "has_res": os.path.isfile(res_path),
        "classification": "other",
        "evidence": "",
    }

    if not result["has_res"]:
        result["classification"] = "missing_res"
        result["evidence"] = f"no .res file at {res_path}"
        return result

    if has_csv:
        result["classification"] = "complete"
        return result

    # Read head+tail of .res file (avoids reading multi-GB files fully)
    try:
        head, tail, file_size = _read_head_tail(res_path)
    except OSError as e:
        result["classification"] = "other"
        result["evidence"] = str(e)
        return result

    # Check for crash signals in head and tail
    for chunk in (head, tail):
        for line in chunk.split('\n'):
            for pat in CRASH_PATTERNS:
                if pat.search(line):
                    result["classification"] = "crash_abort"
                    result["evidence"] = line.strip()[:200]
                    return result

    # Summary lines are in the tail
    has_dump = bool(DUMP_PATTERN.search(tail))
    tp_match = THROUGHPUT_PATTERN.search(tail)
    has_stats = bool(STATISTICS_PATTERN.search(tail))
    has_shutdown = bool(SHUTDOWN_PATTERN.search(tail))

    if has_dump:
        # Server dumped CSV but we don't have it locally
        result["classification"] = "scp_pull_gap"
        m = DUMP_PATTERN.search(tail)
        result["evidence"] = f"server dumped CSV ({m.group(0)}) but file missing locally"
        return result

    if tp_match:
        tp = float(tp_match.group(1))
        if tp < 0.01:
            result["classification"] = "zero_throughput"
            result["evidence"] = f"Mid throughput is {tp}"
            return result

    if not has_stats and not has_dump:
        if has_shutdown:
            result["classification"] = "timeout"
            result["evidence"] = "server_shutdown without statistics or CSV dump"
        elif file_size < 5000:
            result["classification"] = "timeout"
            result["evidence"] = f"very short .res file ({file_size} bytes), likely killed early"
        else:
            result["classification"] = "never_dumped"
            result["evidence"] = "has content but no statistics/dump lines"
        return result

    if has_stats and not has_dump:
        result["classification"] = "never_dumped"
        result["evidence"] = "has statistics but no CSV dump line"
        return result

    return result


def scan_prefixes(result_dir, servers=None):
    """Scan result directory and return {prefix: {server: classification_dict}}.

    A prefix is everything before -zoo[0-4].{res,csv}.
    """
    if servers is None:
        servers = DEFAULT_SERVERS

    server_pattern = '|'.join(re.escape(s) for s in servers)
    file_re = re.compile(rf'^(.+)-({server_pattern})\.(res|csv)$')

    # Collect all prefixes and which files exist
    prefix_files = defaultdict(lambda: {"res": set(), "csv": set()})
    for fname in os.listdir(result_dir):
        m = file_re.match(fname)
        if m:
            prefix, server, ext = m.groups()
            prefix_files[prefix][ext].add(server)

    # Classify each server for each prefix
    results = {}
    for prefix in sorted(prefix_files.keys()):
        info = prefix_files[prefix]
        # Only consider prefixes that have at least one .res file
        if not info["res"]:
            continue

        server_results = {}
        for server in servers:
            has_csv = server in info["csv"]
            res_path = os.path.join(result_dir, f"{prefix}-{server}.res")
            server_results[server] = classify_server(res_path, has_csv)

        results[prefix] = server_results

    return results


def build_audit_report(scan_results, servers=None):
    """Build structured audit report from scan results.

    Returns dict with:
      summary: {total_prefixes, complete, incomplete, by_cause}
      incomplete_prefixes: [{prefix, csv_count, res_count, servers: {server: {classification, evidence}}}]
    """
    if servers is None:
        servers = DEFAULT_SERVERS

    n_servers = len(servers)
    complete = 0
    incomplete = []
    cause_counts = defaultdict(int)

    for prefix, server_data in sorted(scan_results.items()):
        csv_count = sum(1 for s in server_data.values() if s["has_csv"])
        res_count = sum(1 for s in server_data.values() if s["has_res"])

        if csv_count == n_servers:
            complete += 1
            continue

        # Collect causes for missing CSVs
        missing_servers = {}
        for server, info in server_data.items():
            if not info["has_csv"]:
                cause_counts[info["classification"]] += 1
                missing_servers[server] = {
                    "classification": info["classification"],
                    "evidence": info["evidence"],
                }

        incomplete.append({
            "prefix": prefix,
            "csv_count": csv_count,
            "res_count": res_count,
            "expected": n_servers,
            "missing_servers": missing_servers,
        })

    # Determine dominant cause per prefix
    for entry in incomplete:
        causes = [s["classification"] for s in entry["missing_servers"].values()]
        # Most common cause
        cause_freq = defaultdict(int)
        for c in causes:
            cause_freq[c] += 1
        entry["dominant_cause"] = max(cause_freq, key=cause_freq.get)

    report = {
        "summary": {
            "total_prefixes": len(scan_results),
            "complete": complete,
            "incomplete": len(incomplete),
            "by_cause": dict(cause_counts),
        },
        "incomplete_prefixes": incomplete,
    }
    return report


def export_report(report, output_path):
    """Write audit report as JSON."""
    os.makedirs(os.path.dirname(output_path) if os.path.dirname(output_path) else '.', exist_ok=True)
    with open(output_path, 'w') as f:
        json.dump(report, f, indent=2)
    print(f"Saved: {output_path}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    result_dir = sys.argv[1]
    if not os.path.isdir(result_dir):
        print(f"Error: {result_dir} is not a directory")
        sys.exit(1)

    servers = DEFAULT_SERVERS
    if "--servers" in sys.argv:
        idx = sys.argv.index("--servers")
        servers = sys.argv[idx + 1].split(",")

    print(f"Scanning {result_dir} for experiment prefixes...")
    scan_results = scan_prefixes(result_dir, servers)
    print(f"Found {len(scan_results)} prefixes")

    report = build_audit_report(scan_results, servers)

    output_path = os.path.join(result_dir, "csv_audit.json")
    export_report(report, output_path)

    # Print summary
    s = report["summary"]
    print(f"\nCSV Audit Summary:")
    print(f"  Total prefixes:    {s['total_prefixes']}")
    print(f"  Complete (5/5):    {s['complete']}")
    print(f"  Incomplete:        {s['incomplete']}")
    print(f"\n  Missing CSV causes:")
    for cause, count in sorted(s["by_cause"].items(), key=lambda x: -x[1]):
        print(f"    {cause:<20s} {count:>4d} server-files")

    # Print first 20 incomplete prefixes
    print(f"\nFirst 20 incomplete prefixes:")
    for entry in report["incomplete_prefixes"][:20]:
        print(f"  {entry['prefix']}")
        print(f"    csv={entry['csv_count']}/{entry['expected']}  "
              f"dominant_cause={entry['dominant_cause']}")
        for server, info in entry["missing_servers"].items():
            print(f"      {server}: {info['classification']}"
                  f"  [{info['evidence'][:80]}]")


if __name__ == "__main__":
    main()
