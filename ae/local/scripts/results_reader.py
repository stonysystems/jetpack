import re
import os

# Directory where files are stored
directory = "test_output"
pattern = re.compile(r"test-server(\d+)\.res$")

# 1. List & filter
if not os.path.isdir(directory):
    print(f"Error: Directory '{directory}' not found.")
    exit()
raw = [f for f in os.listdir(directory)
       if f.startswith("test") and f.endswith(".res")]

# 2. Sort by the integer captured in the filename
raw.sort(key=lambda fn: int(pattern.search(fn).group(1)))

# 3. Prepend the directory
files = [os.path.join(directory, fn) for fn in raw]

# Variables to accumulate results
total_throughput = 0
total_attempted = 0
total_successed = 0
total_efficient_successed = 0

latency_strings = []
loadyml_contents = []
success_rates = []
efficient_success_rates = []

# CPU usage accumulators
total_cpu_usage = 0.0
cpu_usages = []

# Patterns
throughput_pattern = re.compile(r"Mid throughput is ([\d.]+)")
total_throughput_pattern = re.compile(r"Total throughtput is ([\d.]+)")
efficient_latency_pattern = re.compile(
    r"All-efficient-attempts.*?50pct\s+([\d.]+)\s+90pct\s+([\d.]+)\s+99pct\s+([\d.]+)")
loadyml_pattern = re.compile(r"LoadYML:\s*(.*)")
fastpath_pattern = re.compile(
    r"Fastpath statistics attempted (\d+) successed (\d+) rate\(pct\) ([\d.]+) efficient_successed (\d+) efficient_rate\(pct\) ([\d.]+)")
cpu_pattern = re.compile(r"server median : ([\d.]+)")

# Process each file
for file_path in files:
    with open(file_path, 'r') as f:
        content = f.read()

        # Throughput — prefer Mid, fall back to Total for shorter runs
        m = throughput_pattern.search(content)
        if m:
            total_throughput += float(m.group(1))
        else:
            m = total_throughput_pattern.search(content)
            if m:
                total_throughput += float(m.group(1))

        # Latency from All-efficient-attempts line
        m = efficient_latency_pattern.search(content)
        if m:
            p50, p90, p99 = map(float, m.groups())
            # Round if >10
            p50 = round(p50) if p50 > 10 else p50
            p90 = round(p90) if p90 > 10 else p90
            p99 = round(p99) if p99 > 10 else p99
            latency_strings.append(f"{p50}-{p90}-{p99}")

        # LoadYML
        loadyml_contents.extend(loadyml_pattern.findall(content))

        # Fastpath
        m = fastpath_pattern.search(content)
        if m:
            attempted = int(m.group(1))
            successed = int(m.group(2))
            efficient_succ = int(m.group(4))
            total_attempted += attempted
            total_successed += successed
            total_efficient_successed += efficient_succ
            # Per-file rates
            success_rates.append(successed/attempted*100 if attempted else 0)
            efficient_success_rates.append(efficient_succ/attempted*100 if attempted else 0)

        # CPU usage
        m = cpu_pattern.search(content)
        if m:
            cpu = float(m.group(1))
            cpu_usages.append(cpu)
            total_cpu_usage += cpu

# Final computations
throughput_k = total_throughput/1000
cumul_succ_rate = total_successed/total_attempted*100 if total_attempted else 0
cumul_eff_rate = total_efficient_successed/total_attempted*100 if total_attempted else 0
avg_cpu = total_cpu_usage/len(cpu_usages) if cpu_usages else 0

# Print results
print(f"Total Throughput: {total_throughput}")
print(f"Total Throughput (k): {throughput_k:.2f} k")
print("Latencies (p50-p90-p99):", " / ".join(latency_strings))
print(f"Average CPU Usage: {avg_cpu:.2f}%")
print("Individual CPU Usages:", " / ".join(f"{cpu:.2f}%" for cpu in cpu_usages))
print("LoadYML contents:", loadyml_contents)
print(f"Success rate: {cumul_succ_rate:.2f}% ({' / '.join(f'{r:.2f}%' for r in success_rates)})")
print(f"Efficient success rate: {cumul_eff_rate:.2f}% ({' / '.join(f'{r:.2f}%' for r in efficient_success_rates)})")
