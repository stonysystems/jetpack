#!/usr/bin/env python3
"""Parse cpustat files from /proc/stat polling and report per-core and host CPU usage."""
import sys
import os

def parse_cpu_line(line):
    """Parse a /proc/stat cpu line: 'cpuN user nice system idle iowait irq softirq steal [guest gnice]'"""
    parts = line.split()
    name = parts[0]
    vals = [int(x) for x in parts[1:]]
    # user nice system idle iowait irq softirq steal
    total = sum(vals[:8])
    idle = vals[3] + vals[4]  # idle + iowait
    return name, total, idle

def compute_usages(cpustat_file, core_name):
    """Compute per-second CPU usage for a given core (e.g. 'cpu1') or aggregate ('cpu')."""
    samples = []
    with open(cpustat_file) as f:
        for line in f:
            line = line.strip()
            if core_name == 'cpu' and line.startswith('cpu '):
                samples.append(parse_cpu_line(line))
            elif core_name != 'cpu' and line.startswith(core_name + ' '):
                samples.append(parse_cpu_line(line))

    usages = []
    for i in range(1, len(samples)):
        _, t1, id1 = samples[i-1]
        _, t2, id2 = samples[i]
        dt = t2 - t1
        di = id2 - id1
        if dt > 0:
            usage = 100.0 * (1.0 - di / dt)
            usages.append(usage)
    return usages

def main():
    if len(sys.argv) < 2:
        print("Usage: parse_cpustat.py <result_dir> <label> [core_id]")
        sys.exit(1)

    result_dir = sys.argv[1]
    label = sys.argv[2]
    core_id = int(sys.argv[3]) if len(sys.argv) > 3 else 1

    replicas = ['zoo1', 'zoo2', 'zoo3', 'zoo4', 'zoo5']

    for replica in replicas:
        cpufile = os.path.join(result_dir, f"{label}-{replica}-cpustat.txt")
        if not os.path.isfile(cpufile):
            print(f"  {replica}: no CPU data")
            continue

        core_usages = compute_usages(cpufile, f"cpu{core_id}")
        host_usages = compute_usages(cpufile, 'cpu')

        if core_usages:
            c_avg = sum(core_usages) / len(core_usages)
            c_max = max(core_usages)
        else:
            c_avg = c_max = 0

        if host_usages:
            h_avg = sum(host_usages) / len(host_usages)
            h_max = max(host_usages)
        else:
            h_avg = h_max = 0

        print(f"  {replica}: core{core_id} avg={c_avg:.1f}% max={c_max:.1f}%  |  host avg={h_avg:.1f}% max={h_max:.1f}%")

if __name__ == '__main__':
    main()
