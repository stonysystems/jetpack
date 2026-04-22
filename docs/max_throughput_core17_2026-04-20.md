# Max-Throughput Core-17 Sweep — 2026-04-20

Applies the canonical setting in [docs/max_throughput_experiment_setting.md](max_throughput_experiment_setting.md): server thread pinned to **core 17**, leader-routing protocols placed at zoo2, clients uniformly distributed, N=1 baseline co-located with the leader, adaptive sweep (N=1, 50, 100, extend/bisect) with stop at `zoo2 p50 > 2 × baseline`. Headline CPU number is the avg across the 5 hosts' mid-10 s core-17 means (not max-across-hosts).

All result dirs: `results/2026-04-20-<proto>-core17/` with per-N `.res`, `cpustat.txt`, and `SETTING.md` snapshots. Driver: [scripts/run_tier1_batch.sh](../scripts/run_tier1_batch.sh) + [scripts/run_adaptive_sweep.sh](../scripts/run_adaptive_sweep.sh).

**Leader placement note** (2026-04-20 rerun of raft-family protocols): raft, jp-raft-fp100, and jp-raft-adaptive were rerun after biasing the Raft election timer toward `locale_id=1` (see [src/deptran/raft/server.cc:919](../src/deptran/raft/server.cc#L919)) and adding `MODE_RAFT`/`MODE_FPGA_RAFT` to [Communicator::GetLeaderForPartition](../src/deptran/communicator.cc#L1775) so clients route to zoo2 by default. The original-pass (zoo1-leader) result dirs are kept under `results/2026-04-20-<proto>-core17-zoo1leader/` for comparison but are not authoritative.

## Peak per protocol

Ranked by peak `cmd/s`.

| Protocol | Peak (cmd/s) | N | zoo2 p50 (ms) | zoo2 p90 | zoo2 p99 | zoo3 p50 | zoo1 cpu | zoo2 cpu | zoo3 cpu | zoo4 cpu | zoo5 cpu | **avg cpu** |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **naive_epaxos** | **44 284** | 231 | 122.9 | 180.2 | 280.7 | 152.1 | 95.5 | 88.7 | 96.8 | 98.1 | 99.5 | **95.7** |
| **epaxos** | **27 363** | 137 | 78.2 | 236.7 | 546.9 | 78.8 | 99.5 | 18.2 | 52.5 | 57.7 | 25.5 | **50.7** |
| **naive_raft** | **18 004** | 90 | 87.5 | 153.1 | 217.2 | 88.0 | 23.1 | 99.8 | 48.6 | 59.6 | 29.7 | **52.2** |
| **swiftpaxos** | **16 788** | 84 | 43.3 | 44.5 | 68.5 | 43.5 | 99.9 | 69.6 | 93.9 | 93.8 | 83.0 | **88.0** |
| **raft (zoo2)** | **16 790** | 84 | 98.9 | 146.4 | 205.9 | 99.2 | 21.1 | **99.5** | 49.9 | 57.6 | 28.1 | **51.3** |
| **jp-raft-adaptive (zoo2)** | **14 189** | 71 | 44.9 | 54.6 | 78.3 | 45.2 | 53.6 | **100.0** | 92.1 | 92.5 | 76.3 | **82.9** |
| **jp-raft-fp100 (zoo2)** | **13 586** | 68 | 44.5 | 53.8 | 81.5 | 44.9 | 52.2 | **99.9** | 92.7 | 93.6 | 73.7 | **82.4** |
| **etcd** | **13 002** | 65 | 89.0 | 98.1 | 118.0 | 89.5 | 99.9 | 5.7 | 14.6 | 16.5 | 7.4 | **28.8** |
| **CURP (zoo2)** | **11 973** | 60 | 44.2 | 56.9 | 89.2 | 44.4 | 49.9 | **96.2** | 86.0 | 81.9 | 68.9 | **76.6** |

**Raft leader on zoo2 confirmed.** At peak N=84 the raft leader core (zoo2) pins at **99.5 %** while the other four replicas sit at 21–57 %. This matches the experiment spec ("if the protocol has a leader/master/unique server, put it on zoo2"). See the per-protocol CSVs for the bisection rows that bracket the peak.

**Stable-leader fix** (rerun of raft-family after the earlier pass had tput=0 holes between N=50 and N=100): with `RAFT_ELECTION_ONLY_INIT_AND_POST_FAILURE_ONCE_PATCH` defined, a saturated zoo2 would miss heartbeats, zoo1's election timer would fire, zoo1 would steal leadership with a higher term, and the patch would then block zoo2 from re-winning — leadership thrashed and latency collapsed. Fix: election timeout for `locale_id != 1` set to `20 × 1000 × HEARTBEAT_INTERVAL` (~100 s), well beyond the 30 s experiment duration, so non-zoo2 replicas never time out in-test even if heartbeats slip. With this, jp-raft-fp100 peaks at **13 586** (+36 % vs 10 003 before) and jp-raft-adaptive at **14 189** (+42 % vs 9 981). Adaptive now beats fp100 at saturation — the throttle's CPU-threshold disable (added [src/deptran/rule/coordinator.cc](../src/deptran/rule/coordinator.cc)) kicks in and lets the leader spend cycles on raft replication instead of failed spec RPCs.

Notes on saturation-detection quirks:

- **etcd peak is still zoo1-bound.** Only zoo1 opens the etcd connection pool (per `src/deptran/etcd/server.h:51`, only `locale_id=0` creates connections), so the 5-host avg (28.8 %) badly under-reports what's happening on zoo1 (99.9 %). The real bottleneck is zoo1's single core.

## Peak ordering

**naive_epaxos > epaxos > naive_raft > swiftpaxos ≈ raft > jp-raft-adaptive ≈ jp-raft-fp100 > etcd > CURP.**

Two notable clusters:

1. **Distributed-leader protocols dominate.** naive_epaxos (44 k), epaxos (27 k), and naive_raft (18 k) distribute work across all 5 replicas and hit 44 k+ peaks because no single replica pins until much later in the sweep. naive_epaxos's peak is **2.5 × naive_raft's** — the "per-site leader" design (every server is a leader for its own local clients) spreads write load evenly, while naive_raft concentrates all writes on zoo2.
2. **Fixed-leader protocols pin early.** raft (zoo2), swiftpaxos, jp-raft-*, etcd (zoo1 only for connection pool) all hit their ceiling when a single replica reaches ~100 % core-17 CPU. Raft and SwiftPaxos peaks are nearly identical (~16–17 k cmd/s); both saturate the leader core at similar rates. SwiftPaxos keeps p50 at ~43 ms (1 RTT) while Raft's p50 stays near 99 ms at peak (still comfortably under the 156 ms stop threshold). Jetpack+Raft variants trade peak for latency: ~13–14 k cmd/s at 45 ms p50 — lower ceiling than plain Raft because the fast-path spec RPCs compete with raft replication on the same pinned leader core.

**CURP notes.** Peak 11 973 @ N=60 with 5-host avg 76.6 % (zoo2 96.2 %, zoo3/4 80–86 %, zoo5 69 %, zoo1 50 %). The adaptive sweep only gave us two usable points (N=50, N=100 — the rest collapsed to tput=0 or bimodal p99 > 7 s), so a dense manual sweep at N=55/60/65/70 located the real saturation between N=60 and N=65. Above N=60, zoo2 pins at 100 % and p99 spikes into seconds while p50 stays at 42 ms — a sign of long tail queueing, not clean saturation. CURP peaks lower than jp-raft-* despite the leader-skip optimization because witness replicas (zoo3/4/5) still do `command_pool_.push_back` on every command, so non-leader CPU is ~69–86 % here vs 74–94 % for jp-raft-fp100 — similar distributed cost, but plain Raft replication runs alongside the CURP speculative path on the leader.

## Baseline latencies at N=1 (client co-located with leader)

Measured zoo2 p50 at N=1 (used as stop_p50 / 2). All baselines are inflated by 2 × `WAN_DELAY_MS` (40 ms) for the leader ↔ follower RTT; the "colocated" client ↔ leader hop also pays the WAN delay because `_wan_wait()` is currently unconditional (see TODO — optional WAN-aware WAN_WAIT).

| Protocol | Baseline (ms) | Notes |
|---|---:|---|
| raft | 78.24 | 2 × 20 ms RTT (client→leader, leader→follower) |
| etcd | 82.75 | 2 × RTT + internal |
| naive_raft | 82.73 | client→zoo2 + zoo2→follower wait |
| naive_epaxos | 82.63 | client→local-leader + leader→follower wait |
| swiftpaxos | 41.81 | 1-RTT |
| epaxos | 41.51 | 1-RTT |
| jp-raft-fp100 | 41.63 | 1-RTT |
| jp-raft-adaptive | 41.61 | 1-RTT |
| CURP | 41.58 | 1-RTT |

## Full per-N detail per protocol

Every N attempted during the adaptive sweep (baseline + 50/100 probes + upward extension + bisection), in search order. **Bold** tput = peak (max unsaturated throughput, matches the headline Peak table above). Throughput is cluster-wide `cmd/s` from the mid-10 s window; p50/p90/p99 are client-reported, in ms; per-host cpu is the core-17 mean %. `—` in CPU columns means a missing/zero sample (`/proc/stat` sampling sometimes fails on a host); `**0**` in the tput column means the run failed to produce a Mid-throughput reading (segfault / saturation crash).

Column semantics match the Peak per protocol table above. `stopped` is the adaptive-sweep verdict: `baseline` = N=1 seed, `ok` = probe under 2× baseline, `stop` = probe over 2× baseline (triggered search termination), `bisect-ok`/`bisect-stop` = bisection step outcome, `manual` = manually-run point outside the adaptive sweep (CURP only — N=55/60/65/70 were added by hand because the bisection collapsed at N=100).

Source CSVs: `<result_dir>/<proto>-adaptive.csv`; regeneration: [scripts/build_per_protocol_tables.py](../scripts/build_per_protocol_tables.py).

### naive_epaxos

| N | tput | zoo2 p50 | zoo2 p90 | zoo2 p99 | zoo3 p50 | zoo1 cpu | zoo2 cpu | zoo3 cpu | zoo4 cpu | zoo5 cpu | avg cpu | stopped |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---|
| 1 | 197 | 82.63 | 83.50 | 84.18 | -1.00 | — | 2.9 | — | — | — | 0.6 | baseline |
| 50 | 9 991 | 81.76 | 82.51 | 83.45 | 82.55 | 41.6 | 46.0 | 83.2 | 88.5 | 60.5 | 64.0 | ok |
| 100 | 19 985 | 81.90 | 82.77 | 101.73 | 82.50 | 78.2 | 87.2 | 94.7 | 95.9 | 95.0 | 90.2 | ok |
| 150 | 29 970 | 82.65 | 83.47 | 97.39 | 83.77 | 94.5 | 98.1 | 99.5 | 98.6 | 99.6 | 98.1 | ok |
| 200 | 39 781 | 85.73 | 106.61 | 191.45 | 90.26 | 93.9 | 92.2 | 97.4 | 97.7 | 98.9 | 96.0 | ok |
| 300 | 45 309 | 612.79 | 794.07 | 986.12 | 1315.98 | 99.6 | 98.4 | 98.7 | 98.4 | 99.2 | 98.9 | stop |
| 250 | 45 090 | 303.72 | 428.25 | 575.51 | 848.90 | 96.6 | 93.6 | 98.6 | 98.2 | 99.2 | 97.2 | bisect-stop |
| 225 | 43 918 | 109.57 | 150.36 | 263.09 | 142.11 | 94.9 | 89.9 | 98.8 | 98.4 | 99.6 | 96.3 | bisect-ok |
| 237 | 43 629 | 175.23 | 252.89 | 377.41 | 283.60 | 95.8 | 90.4 | 98.7 | 98.4 | 99.1 | 96.5 | bisect-stop |
| 231 | **44 284** | 122.89 | 180.19 | 280.68 | 152.10 | 95.5 | 88.7 | 96.8 | 98.1 | 99.5 | 95.7 | bisect-ok |
| 234 | 43 628 | 148.64 | 231.41 | 382.84 | 193.90 | 94.9 | 89.9 | 97.1 | 98.2 | 99.8 | 96.0 | bisect-ok |

### epaxos

| N | tput | zoo2 p50 | zoo2 p90 | zoo2 p99 | zoo3 p50 | zoo1 cpu | zoo2 cpu | zoo3 cpu | zoo4 cpu | zoo5 cpu | avg cpu | stopped |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---|
| 1 | 201 | 41.51 | 42.18 | 42.64 | -1.00 | — | 1.1 | — | — | — | 0.2 | baseline |
| 50 | 10 000 | 41.53 | 42.23 | 51.94 | 41.79 | 67.3 | 25.2 | 59.1 | 61.9 | 33.0 | 49.3 | ok |
| 100 | 19 984 | 41.97 | 42.89 | 64.25 | 42.24 | 97.3 | 53.5 | 82.6 | 85.5 | 49.3 | 73.6 | ok |
| 150 | 29 654 | 210.03 | 745.48 | 1120.96 | 205.48 | 99.5 | 9.4 | 17.9 | 15.3 | 8.6 | 30.1 | stop |
| 125 | 24 990 | 65.89 | 91.27 | 250.49 | 66.50 | 100.0 | 31.6 | 73.7 | 80.9 | 39.9 | 65.2 | bisect-ok |
| 137 | **27 363** | 78.20 | 236.65 | 546.88 | 78.79 | 99.5 | 18.2 | 52.5 | 57.7 | 25.5 | 50.7 | bisect-ok |
| 143 | 28 525 | 89.32 | 430.45 | 841.74 | 90.04 | 99.9 | 24.5 | 37.5 | 48.6 | 20.4 | 46.2 | bisect-stop |
| 140 | 27 696 | 127.65 | 659.21 | 1266.62 | 127.56 | 99.8 | 13.8 | 24.1 | 24.2 | 12.3 | 34.9 | bisect-stop |

### naive_raft

| N | tput | zoo2 p50 | zoo2 p90 | zoo2 p99 | zoo3 p50 | zoo1 cpu | zoo2 cpu | zoo3 cpu | zoo4 cpu | zoo5 cpu | avg cpu | stopped |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---|
| 1 | 198 | 82.73 | 83.62 | 84.29 | -1.00 | — | 2.4 | — | — | — | 0.5 | baseline |
| 50 | 9 997 | 82.08 | 82.88 | 86.62 | 82.52 | 22.4 | 96.9 | 44.1 | 58.7 | 31.2 | 50.7 | ok |
| 100 | 16 891 | 1100.15 | 1254.02 | 1385.52 | 1092.24 | 17.1 | 100.0 | 38.4 | 48.5 | 20.7 | 44.9 | stop |
| 75 | 15 009 | 83.41 | 84.38 | 98.58 | 83.86 | 23.1 | 99.7 | 51.9 | 56.8 | 30.3 | 52.4 | bisect-ok |
| 87 | 17 401 | 84.29 | 85.49 | 147.91 | 84.75 | 24.4 | 99.9 | 46.1 | 56.2 | 30.2 | 51.4 | bisect-ok |
| 93 | 17 369 | 863.01 | 984.72 | 1129.64 | 864.54 | 20.0 | 100.0 | 40.2 | 48.0 | 23.5 | 46.3 | bisect-stop |
| 90 | **18 004** | 87.47 | 153.11 | 217.21 | 88.03 | 23.1 | 99.8 | 48.6 | 59.6 | 29.7 | 52.1 | bisect-ok |

### swiftpaxos

| N | tput | zoo2 p50 | zoo2 p90 | zoo2 p99 | zoo3 p50 | zoo1 cpu | zoo2 cpu | zoo3 cpu | zoo4 cpu | zoo5 cpu | avg cpu | stopped |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---|
| 1 | 198 | 41.81 | 42.50 | 42.93 | -1.00 | — | 3.8 | — | — | — | 0.8 | baseline |
| 50 | 10 001 | 42.00 | 42.81 | 97.72 | 42.26 | 93.6 | 82.7 | 92.9 | 94.5 | 91.1 | 91.0 | ok |
| 100 | 16 837 | 1099.27 | 1238.13 | 1413.83 | 1111.90 | 100.0 | 34.0 | 75.4 | 80.6 | 49.3 | 67.9 | stop |
| 75 | 14 975 | 42.68 | 43.74 | 111.07 | 42.97 | 99.6 | 76.8 | 94.7 | 91.0 | 88.7 | 90.2 | bisect-ok |
| 87 | 16 427 | 833.97 | 938.50 | 1035.26 | 829.34 | 100.0 | 33.1 | 76.8 | 79.8 | 48.8 | 67.7 | bisect-stop |
| 81 | 16 189 | 43.02 | 44.22 | 101.96 | 43.33 | 100.0 | 71.7 | 94.2 | 95.0 | 84.7 | 89.1 | bisect-ok |
| 84 | **16 788** | 43.25 | 44.46 | 68.51 | 43.54 | 99.9 | 69.6 | 93.9 | 93.8 | 83.0 | 88.0 | bisect-ok |

### raft (zoo2 leader)

| N | tput | zoo2 p50 | zoo2 p90 | zoo2 p99 | zoo3 p50 | zoo1 cpu | zoo2 cpu | zoo3 cpu | zoo4 cpu | zoo5 cpu | avg cpu | stopped |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---|
| 1 | 199 | 77.92 | 88.59 | 92.75 | -1.00 | — | 2.2 | — | — | — | 0.4 | baseline |
| 50 | 9 982 | 79.12 | 87.00 | 95.36 | 79.63 | 14.3 | 66.5 | 35.5 | 38.4 | 20.9 | 35.1 | ok |
| 100 | 15 850 | 1188.59 | 1337.38 | 1418.16 | 1208.57 | 21.9 | 100.0 | 40.9 | 45.6 | 27.2 | 47.1 | stop |
| 75 | 14 997 | 88.51 | 97.99 | 128.99 | 88.95 | 20.1 | 93.5 | 44.0 | 51.6 | 30.5 | 47.9 | bisect-ok |
| 87 | 16 270 | 867.27 | 973.73 | 1093.94 | 868.27 | 22.8 | 100.0 | 45.9 | 50.2 | 29.1 | 49.6 | bisect-stop |
| 81 | 16 196 | 93.41 | 102.09 | 141.53 | 93.92 | 19.3 | 97.8 | 49.0 | 63.8 | 27.5 | 51.5 | bisect-ok |
| 84 | **16 790** | 98.89 | 146.39 | 205.87 | 99.24 | 21.1 | 99.5 | 49.9 | 57.6 | 28.1 | 51.3 | bisect-ok |

### jp-raft-adaptive (zoo2 leader)

| N | tput | zoo2 p50 | zoo2 p90 | zoo2 p99 | zoo3 p50 | zoo1 cpu | zoo2 cpu | zoo3 cpu | zoo4 cpu | zoo5 cpu | avg cpu | stopped |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---|
| 1 | 200 | 41.56 | 42.25 | 42.67 | -1.00 | — | 4.0 | — | — | — | 0.8 | baseline |
| 50 | 9 996 | 42.18 | 46.89 | 72.55 | 42.50 | 40.5 | 88.8 | 83.9 | 89.3 | 56.6 | 71.8 | ok |
| 62 | 12 382 | 43.33 | 52.29 | 75.78 | 43.65 | 47.9 | 98.6 | 90.5 | 91.9 | 67.6 | 79.3 | bisect-ok |
| 68 | 13 576 | 44.43 | 53.25 | 82.15 | 44.69 | 52.9 | 99.8 | 92.2 | 93.2 | 72.0 | 82.0 | bisect-ok |
| 71 | **14 189** | 44.91 | 54.55 | 78.34 | 45.19 | 53.6 | 100.0 | 92.1 | 92.5 | 76.3 | 82.9 | bisect-ok |
| 75 | 10 868 | 333.41 | 919.95 | 9729.68 | 343.58 | 39.2 | 100.0 | 78.6 | 83.9 | 51.9 | 70.7 | bisect-stop |
| 100 | 4 236 | 958.79 | 26712.53 | 29917.69 | 880.09 | 15.9 | 100.0 | 44.5 | 50.4 | 24.5 | 47.0 | stop |

### jp-raft-fp100 (zoo2 leader)

| N | tput | zoo2 p50 | zoo2 p90 | zoo2 p99 | zoo3 p50 | zoo1 cpu | zoo2 cpu | zoo3 cpu | zoo4 cpu | zoo5 cpu | avg cpu | stopped |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---|
| 1 | 201 | 41.62 | 42.33 | 42.72 | -1.00 | — | 2.8 | — | — | — | 0.6 | baseline |
| 50 | 9 988 | 42.34 | 48.01 | 79.79 | 42.67 | 39.7 | 90.8 | 84.6 | 88.5 | 57.1 | 72.2 | ok |
| 62 | 12 388 | 43.32 | 51.48 | 82.12 | 43.61 | 49.3 | 98.7 | 92.4 | 91.2 | 68.0 | 79.9 | bisect-ok |
| 68 | **13 586** | 44.53 | 53.77 | 81.53 | 44.87 | 52.2 | 99.9 | 92.7 | 93.6 | 73.7 | 82.4 | bisect-ok |
| 71 | 13 747 | 166.66 | 384.17 | 3173.69 | 167.29 | 50.0 | 100.0 | 86.6 | 88.2 | 66.0 | 78.2 | bisect-stop |
| 75 | 11 230 | 336.01 | 825.86 | 9894.06 | 338.60 | 38.5 | 100.0 | 78.7 | 85.3 | 54.5 | 71.4 | bisect-stop |
| 100 | 4 469 | 804.53 | 27286.22 | 31209.20 | 836.69 | 15.5 | 100.0 | 40.6 | 44.7 | 23.1 | 44.8 | stop |

### etcd

| N | tput | zoo2 p50 | zoo2 p90 | zoo2 p99 | zoo3 p50 | zoo1 cpu | zoo2 cpu | zoo3 cpu | zoo4 cpu | zoo5 cpu | avg cpu | stopped |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---|
| 1 | 202 | 82.75 | 83.86 | 84.78 | -1.00 | — | 1.7 | — | — | — | 0.3 | baseline |
| 50 | 10 013 | 82.65 | 83.55 | 93.09 | 83.00 | 99.4 | 8.7 | 20.1 | 22.2 | 11.3 | 32.4 | ok |
| 62 | 12 400 | 85.55 | 88.10 | 119.88 | 85.89 | 99.7 | 6.1 | 17.7 | 17.5 | 8.6 | 29.9 | bisect-ok |
| 65 | **13 002** | 88.97 | 98.05 | 117.99 | 89.46 | 99.9 | 5.7 | 14.6 | 16.5 | 7.4 | 28.8 | bisect-ok |
| 68 | 13 370 | 581.79 | 840.79 | 1004.39 | 571.29 | 99.8 | 3.0 | 6.5 | 10.4 | 5.6 | 25.1 | bisect-stop |
| 75 | 13 719 | 866.11 | 1236.33 | 1454.57 | 860.22 | 100.0 | 2.2 | 5.0 | 7.2 | 4.1 | 23.7 | bisect-stop |
| 100 | 14 446 | 1314.63 | 1683.11 | 2088.34 | 1329.36 | 99.9 | 1.4 | 7.6 | 7.5 | 6.4 | 24.6 | stop |

### CURP (zoo2 leader)

Manual runs at N=55/60/65/70 were added by hand because the adaptive bisection collapsed at N=100 (p50 stayed ~42 ms under the 83 ms stop threshold but p99 spiked into seconds — a bimodal-saturation pattern the p50-only stop criterion doesn't catch).

| N | tput | zoo2 p50 | zoo2 p90 | zoo2 p99 | zoo3 p50 | zoo1 cpu | zoo2 cpu | zoo3 cpu | zoo4 cpu | zoo5 cpu | avg cpu | stopped |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---|
| 1 | 200 | 41.58 | 42.27 | 42.69 | -1.00 | — | 2.3 | — | — | — | 0.5 | baseline |
| 50 | 9 982 | 42.03 | 47.59 | 74.57 | 42.30 | 40.5 | 64.6 | 84.0 | 88.4 | 56.5 | 66.8 | ok |
| 55 | 10 990 | 43.86 | 55.19 | 84.77 | 42.75 | 43.7 | 92.5 | 90.4 | 90.4 | 62.4 | 75.9 | manual |
| 60 | **11 973** | 44.17 | 56.91 | 89.19 | 44.28 | 49.9 | 96.2 | 86.0 | 81.9 | 68.9 | 76.6 | manual |
| 65 | 11 626 | 41.88 | 115.49 | 7179.60 | 42.13 | 44.0 | 100.0 | 86.9 | 88.8 | 57.0 | 75.3 | manual |
| 70 | 7 917 | 41.90 | 755.86 | 17110.86 | 42.15 | 32.1 | 100.0 | 68.4 | 73.5 | 41.7 | 63.1 | manual |
| 100 | 5 428 | 42.02 | 14774.14 | 19693.23 | 42.33 | 21.5 | 100.0 | 56.7 | 64.4 | 35.8 | 55.7 | ok |
| 150 | 0 | — | — | — | — | 18.4 | 100.0 | 43.1 | 52.7 | 25.4 | 47.9 | ok |
| 200 | 0 | — | — | — | — | — | — | — | — | — | — | ok |
| 300 | 0 | — | — | — | — | 17.7 | 99.9 | 35.3 | 46.3 | 28.3 | 45.5 | ok |
| 500 | 0 | — | — | — | — | — | — | — | 87.1 | — | 0.6 | ok |

## Open issues surfaced

1. **Stop criterion fragility** — baseline and stop both look at zoo2 p50 only. When zoo2 reports 0 (missing-data sentinel) at saturated N, the zoo2 clause doesn't trip and bisection runs on other zoo hosts' latencies. A future iteration of the sweep script should fall back to max-across-clients p50 when zoo2 is -1 or 0.
2. **naive_rpc and naive_fastpath** were not rerun under core-17 today. The 2026-04-19 results ([docs/naive_rpc_zoo2_saturation_2026-04-19.md](naive_rpc_zoo2_saturation_2026-04-19.md), [docs/naive_fastpath_2026-04-19.md](naive_fastpath_2026-04-19.md)) are still the reference. The core-17 rerun is a small follow-up if directly-comparable numbers are needed.

## Commands to reproduce

```bash
# Build (docker):
docker build -t jetpack-zoo-build:latest -f docker/zoo-build/Dockerfile .
docker create --name x jetpack-zoo-build:latest
docker cp x:/output/deptran_server build/deptran_server
docker cp x:/output/lib/. build/docker_libs/
docker rm x

# Run the 6-protocol Tier 1 batch:
bash scripts/run_tier1_batch.sh 2026-04-20

# Add naive_epaxos / naive_raft / etc. individually:
SERVER_CORE_ID=17 scripts/run_adaptive_sweep.sh naive_epaxos none_naive_epaxos.yml 0 results/2026-04-20-naive-epaxos-core17
SERVER_CORE_ID=17 scripts/run_adaptive_sweep.sh naive_raft   none_naive_raft.yml   0 results/2026-04-20-naive-raft-core17
```
