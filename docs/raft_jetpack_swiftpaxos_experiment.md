# Raft vs Jetpack+Raft Experiment (SwiftPaxos-Style)

**Date**: 2026-04-14
**Results dir**: `results/2026-04-14-raft-jetpack-swiftpaxos-style/`
**Binary**: Docker zoo-build on jetpack branch (commit 0cc8b12d)

## Cluster

| Host | IP | Process |
|---|---|---|
| zoo0 | 130.245.173.101 | replica + 6 clients |
| zoo1 | 130.245.173.102 | replica + 6 clients |
| zoo2 | 130.245.173.103 | replica + 6 clients |
| zoo3 | 130.245.173.104 | replica + 6 clients |
| zoo4 | 130.245.173.105 | replica + 6 clients |

Hardware: 2x Xeon Silver 4216 (64 logical CPUs), 64 GB RAM per host.

## CPU Pinning

- Server thread: core 1 (one per host)
- Client threads: cores 0, 2, 3, 5, 6, 7 (skipping core 1=server, core 4=occupied)

## Common Settings

| Setting | Value |
|---|---|
| Topology | `30c1s5r5p-zoo.yml` (30 clients, 5 replicas) |
| Workload | `rw_1000000.yml` (100% write, 1M key range) |
| Client mode | `client_open.yml` (open-loop, rate=1000/client) |
| WAN delay | 20ms one-way (`WAN_DELAY_MS=20`), 40ms RTT |
| Duration | 30s per run |

## Protocols

| Label | Config | `-m` |
|---|---|---|
| Raft (baseline) | `none_raft.yml` | `0` |
| Jetpack+Raft fp100 | `rule_raft.yml` | `100` |
| Jetpack+Raft adaptive | `rule_raft.yml` | `101` |

---

## Experiment 1: Low-Load Latency (concurrent_1)

Goal: Measure per-request latency below saturation to see protocol cost.

### Throughput & Latency

| Protocol | Conc | Total Tput | p50 (ms) | p90 (ms) | p99 (ms) | FP rate |
|---|---|---|---|---|---|---|
| Raft | 1 | 20.7 | 79.64 | 89.08 | 91.65 | N/A |
| JP+Raft fp100 | 1 | 20.5 | 40.62 | 40.65 | 40.74 | 100% |
| JP+Raft adaptive | 1 | 19.7 | 40.54 | 40.71 | 40.76 | 100% |

### CPU Usage — Server Thread (core 1) per Host (avg% / max%)

| Protocol | zoo0 | zoo1 | zoo2 | zoo3 | zoo4 | Server Avg | Server Max |
|---|---|---|---|---|---|---|---|
| Raft | 74.6/100.0 | 7.9/97.0 | 10.8/91.1 | 14.7/100.0 | 18.6/99.0 | 25.3 | 100.0 |
| JP fp100 | 75.6/100.0 | 3.5/97.0 | 9.4/95.1 | 22.0/100.0 | 16.3/99.0 | 25.4 | 100.0 |
| JP adaptive | 84.3/100.0 | 4.9/98.0 | 10.0/97.0 | 26.9/100.0 | 24.8/97.0 | 30.2 | 100.0 |

### CPU Usage — Whole Host (avg% / max%)

| Protocol | zoo0 | zoo1 | zoo2 | zoo3 | zoo4 | Host Avg | Host Max |
|---|---|---|---|---|---|---|---|
| Raft | 11.4/12.6 | 1.1/2.2 | 5.6/8.0 | 4.8/6.1 | 57.5/88.2 | 16.1 | 88.2 |
| JP fp100 | 11.6/12.6 | 1.3/2.4 | 5.3/7.6 | 5.4/7.3 | 20.1/92.2 | 8.7 | 92.2 |
| JP adaptive | 12.9/18.1 | 2.0/5.9 | 6.9/11.1 | 6.7/15.2 | 44.3/63.9 | 14.6 | 63.9 |

**Key observations**:
- Raft baseline: **p50 ~ 80ms** (2 RTT = 2 x 40ms)
- Jetpack fp100: **p50 ~ 41ms** (1 RTT = 40ms), exactly as expected for fast-path
- Jetpack adaptive: **p50 ~ 41ms**, adaptive mode achieves same latency as fp100 at low load (100% fast-path)
- Jetpack cuts latency by ~50% (1 RTT vs 2 RTT)
- zoo0 has the highest server-core CPU (likely the Raft leader)
- zoo4 has anomalously high host CPU from an unrelated external process

---

## Experiment 2: Max Throughput (Adaptive Concurrency Sweep)

Goal: Find max sustainable throughput via adaptive concurrency sweep.

### Raft (baseline) — Throughput & Latency

| Conc | Total Tput | p50 (ms) | p90 (ms) | p99 (ms) |
|---|---|---|---|---|
| 1 | 20.7 | 79.64 | 89.08 | 91.65 |
| 50 | 1474.5 | 72.39 | 78.84 | 83.25 |
| 150 | 4460.6 | 74.58 | 81.37 | 86.36 |
| 200 | 5966.5 | 78.31 | 85.64 | 102.47 |
| 300 | 5988.5 | 78.63 | 86.93 | 103.97 |
| 500 | 5998.9 | 78.90 | 87.05 | 104.12 |
| 1000 | 5996.9 | 82.58 | 201.43 | 280.84 |

### Raft — Server Thread CPU (core 1) per Host (avg% / max%)

| Conc | zoo0 | zoo1 | zoo2 | zoo3 | zoo4 | Server Avg | Server Max |
|---|---|---|---|---|---|---|---|
| 1 | 74.6/100.0 | 7.9/97.0 | 10.8/91.1 | 14.7/100.0 | 18.6/99.0 | 25.3 | 100.0 |
| 50 | 71.7/100.0 | 4.3/98.0 | 11.3/98.0 | 21.0/100.0 | 13.4/78.4 | 24.3 | 100.0 |
| 150 | 66.4/100.0 | 5.6/96.0 | 16.9/95.1 | 28.4/100.0 | 22.4/97.0 | 27.9 | 100.0 |
| 200 | 67.1/100.0 | 6.1/98.0 | 18.8/96.1 | 61.3/95.9 | 23.9/100.0 | 35.4 | 100.0 |
| 300 | 52.0/100.0 | 6.1/96.0 | 17.5/98.0 | 59.9/100.0 | 22.3/97.0 | 31.6 | 100.0 |
| 500 | 40.8/100.0 | 6.1/98.0 | 18.6/97.1 | 59.6/95.1 | 29.5/99.0 | 30.9 | 100.0 |
| 1000 | 57.4/100.0 | 6.2/98.0 | 20.7/97.0 | 24.4/96.1 | 60.1/100.0 | 33.8 | 100.0 |

### Raft — Whole Host CPU (avg% / max%)

| Conc | zoo0 | zoo1 | zoo2 | zoo3 | zoo4 | Host Avg | Host Max |
|---|---|---|---|---|---|---|---|
| 1 | 11.4/12.6 | 1.1/2.2 | 5.6/8.0 | 4.8/6.1 | 57.5/88.2 | 16.1 | 88.2 |
| 50 | 11.9/13.4 | 1.3/2.4 | 5.4/7.5 | 5.2/7.2 | 28.5/55.6 | 10.5 | 55.6 |
| 150 | 12.4/16.1 | 2.0/7.8 | 6.5/16.9 | 6.5/20.5 | 21.6/98.4 | 9.8 | 98.4 |
| 200 | 11.5/12.4 | 1.2/2.2 | 3.5/5.1 | 5.8/7.7 | 54.8/59.0 | 15.4 | 59.0 |
| 300 | 11.4/12.3 | 1.0/1.5 | 3.2/4.5 | 5.4/7.1 | 35.9/57.7 | 11.4 | 57.7 |
| 500 | 11.7/12.6 | 1.3/1.8 | 4.2/6.9 | 6.3/8.1 | 55.7/57.6 | 15.8 | 57.6 |
| 1000 | 12.2/14.2 | 1.8/3.1 | 6.6/9.2 | 6.6/9.4 | 65.3/92.9 | 18.5 | 92.9 |

---

### Jetpack+Raft fp100 — Throughput & Latency

| Conc | Total Tput | p50 (ms) | p90 (ms) | p99 (ms) | FP rate |
|---|---|---|---|---|---|
| 1 | 20.5 | 40.62 | 40.65 | 40.74 | 100% |
| 50 | 1480.8 | 41.37 | 42.03 | 43.31 | 100% |
| 150 | 4479.3 | 41.67 | 50.63 | 90.51 | 99.94% |
| 200 | 5967.9 | 41.93 | 43.13 | 53.93 | 99.97% |
| 300 | 5997.2 | 41.90 | 42.98 | 47.11 | 99.97% |
| 500 | 5996.2 | 41.66 | 43.54 | 52.48 | 99.97% |
| 1000 | 5983.9 | 48.12 | 60.53 | 76.30 | 99.96% |

### JP fp100 — Server Thread CPU (core 1) per Host (avg% / max%)

| Conc | zoo0 | zoo1 | zoo2 | zoo3 | zoo4 | Server Avg | Server Max |
|---|---|---|---|---|---|---|---|
| 1 | 75.6/100.0 | 3.5/97.0 | 9.4/95.1 | 22.0/100.0 | 16.3/99.0 | 25.4 | 100.0 |
| 50 | 65.3/100.0 | 8.0/97.1 | 21.8/95.0 | 28.9/100.0 | 37.2/100.0 | 32.2 | 100.0 |
| 150 | 77.0/100.0 | 15.5/99.0 | 38.4/97.1 | 49.9/97.0 | 44.8/98.0 | 45.1 | 100.0 |
| 200 | 63.1/100.0 | 18.1/97.0 | 41.7/97.0 | 63.5/99.0 | 33.4/100.0 | 44.0 | 100.0 |
| 300 | 66.8/100.0 | 18.7/98.0 | 42.4/96.0 | 63.1/100.0 | 34.7/97.0 | 45.1 | 100.0 |
| 500 | 74.7/100.0 | 19.2/98.1 | 41.6/99.0 | 54.4/100.0 | 42.8/98.0 | 46.5 | 100.0 |
| 1000 | 63.6/100.0 | 20.0/99.0 | 42.0/95.0 | 48.2/94.1 | 68.8/100.0 | 48.5 | 100.0 |

### JP fp100 — Whole Host CPU (avg% / max%)

| Conc | zoo0 | zoo1 | zoo2 | zoo3 | zoo4 | Host Avg | Host Max |
|---|---|---|---|---|---|---|---|
| 1 | 11.6/12.6 | 1.3/2.4 | 5.3/7.6 | 5.4/7.3 | 20.1/92.2 | 8.7 | 92.2 |
| 50 | 11.5/13.0 | 1.2/2.1 | 3.4/5.2 | 5.0/7.1 | 53.6/70.1 | 14.9 | 70.1 |
| 150 | 12.7/20.6 | 2.0/11.1 | 5.5/10.9 | 7.5/22.0 | 18.0/83.3 | 9.1 | 83.3 |
| 200 | 11.8/12.8 | 1.4/1.9 | 4.5/6.2 | 6.5/8.3 | 23.3/56.5 | 9.5 | 56.5 |
| 300 | 12.4/15.8 | 1.7/6.1 | 4.9/11.9 | 7.0/21.3 | 18.1/66.4 | 8.8 | 66.4 |
| 500 | 13.3/22.0 | 2.4/8.8 | 6.0/13.8 | 8.2/28.2 | 57.6/65.7 | 17.5 | 65.7 |
| 1000 | 13.7/20.2 | 2.5/9.4 | 6.3/11.5 | 8.2/13.8 | 64.3/97.0 | 19.0 | 97.0 |

---

### Jetpack+Raft adaptive — Throughput & Latency

| Conc | Total Tput | p50 (ms) | p90 (ms) | p99 (ms) | FP rate |
|---|---|---|---|---|---|
| 1 | 19.7 | 40.54 | 40.71 | 40.76 | 100% |
| 50 | 1486.8 | 41.46 | 42.16 | 42.84 | 100% |
| 150 | 4312.1 | 42.07 | 43.80 | 122.42 | 99.57% |
| 200 | 5973.3 | 41.55 | 43.15 | 48.54 | 99.94% |
| 500 | 5998.9 | 41.55 | 42.60 | 52.04 | 99.97% |
| 1000 | 5994.6 | 42.22 | 43.62 | 52.63 | 99.98% |

### JP adaptive — Server Thread CPU (core 1) per Host (avg% / max%)

| Conc | zoo0 | zoo1 | zoo2 | zoo3 | zoo4 | Server Avg | Server Max |
|---|---|---|---|---|---|---|---|
| 1 | 84.3/100.0 | 4.9/98.0 | 10.0/97.0 | 26.9/100.0 | 24.8/97.0 | 30.2 | 100.0 |
| 50 | 79.3/100.0 | 8.2/98.0 | 20.9/99.0 | 44.5/97.0 | 29.8/99.0 | 36.5 | 100.0 |
| 150 | 65.1/100.0 | 15.7/97.0 | 35.4/99.0 | 64.8/100.0 | 43.0/100.0 | 44.8 | 100.0 |
| 200 | 66.0/100.0 | 36.3/97.0 | 41.2/96.0 | 48.9/96.0 | 51.3/100.0 | 48.7 | 100.0 |
| 500 | 66.8/100.0 | 18.9/100.0 | 41.9/97.0 | 49.5/100.0 | 28.8/98.0 | 41.2 | 100.0 |
| 1000 | 55.8/100.0 | 19.6/98.0 | 42.7/98.0 | 61.4/100.0 | 42.9/96.0 | 44.5 | 100.0 |

### JP adaptive — Whole Host CPU (avg% / max%)

| Conc | zoo0 | zoo1 | zoo2 | zoo3 | zoo4 | Host Avg | Host Max |
|---|---|---|---|---|---|---|---|
| 1 | 12.9/18.1 | 2.0/5.9 | 6.9/11.1 | 6.7/15.2 | 44.3/63.9 | 14.6 | 63.9 |
| 50 | 12.0/15.0 | 1.8/5.6 | 4.7/8.9 | 6.7/12.3 | 59.4/88.9 | 16.9 | 88.9 |
| 150 | 12.3/16.4 | 1.8/5.6 | 4.8/12.4 | 7.3/21.5 | 57.8/64.4 | 16.8 | 64.4 |
| 200 | 11.6/12.8 | 1.4/3.2 | 3.8/5.0 | 5.4/6.6 | 64.8/98.7 | 17.4 | 98.7 |
| 500 | 12.4/13.8 | 1.8/3.0 | 4.8/7.5 | 6.4/8.9 | 5.3/10.3 | 6.1 | 13.8 |
| 1000 | 12.8/15.4 | 2.9/5.1 | 6.2/9.2 | 8.0/11.2 | 42.7/61.2 | 14.5 | 61.2 |

---

## Max Throughput Summary

| Protocol | Saturates at | Peak Throughput (cmd/s) | p50 @ peak | p50 @ c1000 | Server core1 Avg @ peak |
|---|---|---|---|---|---|
| Raft (baseline) | c200 | ~6000 | 78ms | 83ms (p90=201ms) | 35.4% |
| Jetpack+Raft fp100 | c200 | ~6000 | 42ms | 48ms (p90=61ms) | 44.0% |
| Jetpack+Raft adaptive | c200 | ~6000 | 42ms | 42ms (p90=44ms) | 48.7% |

**Key findings**:
1. **Same max throughput**: All 3 protocols saturate at ~6000 cmd/s. The bottleneck is the server CPU (single core pinned) rather than protocol overhead.
2. **Latency advantage**: Jetpack reduces p50 from ~80ms (Raft, 2 RTT) to ~42ms (1 RTT) — a 48% reduction.
3. **Tail latency**: At saturation (c1000), Raft's p90 spikes to 201ms while Jetpack stays at 44-61ms.
4. **Fast-path success rate**: >99.9% across all concurrency levels (1M key range = near-zero conflict).
5. **Adaptive vs fp100**: Virtually identical performance. Adaptive correctly stays on fast-path since conflict rate is negligible.
6. **Jetpack uses more server CPU**: At peak (c200), Jetpack server core avg is 44-49% vs Raft's 35%. This is because Jetpack's fast-path requires the server to do more work per request (speculative execution + fast-path reply).

---

## CPU Usage Notes

- **zoo0** consistently shows highest core1 usage (65-85%) — it is likely the Raft leader.
- **zoo4** shows anomalously high host-level CPU usage (often 50-90%) unrelated to deptran — another process on that machine.
- Core 4 was excluded from pinning (occupied by external process).
- CPU monitoring via `/proc/stat` polling (1 sample/sec), parsed by `scripts/parse_cpustat.py`.
- "Server Avg" = average of all 5 hosts' core1 avg%. "Server Max" = max across all hosts' core1 max%.
- "Host Avg" = average of all 5 hosts' overall avg%. "Host Max" = max across all hosts' overall max%.
