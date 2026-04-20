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
| **raft (zoo2)** | **16 276** | 84 | 734.3 | 831.7 | 908.8 | 734.4 | 19.5 | **100.0** | 42.9 | 50.9 | 27.9 | **48.3** |
| **etcd** | **13 002** | 65 | 89.0 | 98.1 | 118.0 | 89.5 | 99.9 | 5.7 | 14.6 | 16.5 | 7.4 | **28.8** |
| **jp-raft-fp100 (zoo2)** | 10 003 | 50 | 42.2 | 46.7 | 68.9 | 42.6 | 41.1 | 89.7 | 84.7 | 88.5 | 56.4 | **72.1** |
| **jp-raft-adaptive (zoo2)** | 9 981 | 50 | 42.3 | 47.2 | 80.8 | 42.6 | 41.5 | 89.7 | 83.9 | 88.5 | 58.5 | **72.4** |

**Raft leader on zoo2 confirmed.** At peak N=84 the raft leader core (zoo2) pins at **100.0 %** while the other four replicas sit at 20–51 %. This matches the experiment spec ("if the protocol has a leader/master/unique server, put it on zoo2"). See the per-protocol CSVs for the bisection rows that bracket the peak.

Notes on saturation-detection quirks the script exposed:

- **jp-raft-fp100 and jp-raft-adaptive still collapse between N=50 and N=100.** N=50 is clean (42 ms p50, ~10 k cmd/s, zoo2=90 % CPU). N≥100 frequently records tput=0 — clients fail to aggregate any commands because zoo2 pins at 100 % and the fast-path speculative RPCs drown out progress. The adaptive CPU-threshold disable we added today ([src/deptran/rule/coordinator.cc](../src/deptran/rule/coordinator.cc), threshold 80 % leader CPU) helped at 50 but didn't prevent the 100-client collapse. The "true" peak for these modes likely sits in [50, 100] and needs either a denser sweep or a tighter adaptive throttle to locate.
- **etcd peak is still zoo1-bound.** Only zoo1 opens the etcd connection pool (per `src/deptran/etcd/server.h:51`, only `locale_id=0` creates connections), so the 5-host avg (28.8 %) badly under-reports what's happening on zoo1 (99.9 %). The real bottleneck is zoo1's single core.

## Peak ordering

**naive_epaxos > epaxos > naive_raft > swiftpaxos ≈ raft > etcd > jp-raft-fp100 ≈ jp-raft-adaptive.**

Two notable clusters:

1. **Distributed-leader protocols dominate.** naive_epaxos (44 k), epaxos (27 k), and naive_raft (18 k) distribute work across all 5 replicas and hit 44 k+ peaks because no single replica pins until much later in the sweep. naive_epaxos's peak is **2.5 × naive_raft's** — the "per-site leader" design (every server is a leader for its own local clients) spreads write load evenly, while naive_raft concentrates all writes on zoo2.
2. **Fixed-leader protocols pin early.** raft (zoo2), swiftpaxos, etcd (zoo1 only for connection pool), and jp-raft-* all hit their ceiling when a single replica reaches ~100 % core-17 CPU. Raft and SwiftPaxos peaks are nearly identical (~16 k cmd/s) because both saturate their leader core at similar rates; SwiftPaxos keeps p50 at ~43 ms (1 RTT) while Raft's p50 blows up to 734 ms once zoo2 pins.

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

## Full per-N tables

CSVs with every N attempted (including bisection steps): `<result_dir>/<proto>-adaptive.csv`. Columns match the canonical presentation spec: N, tput, zoo2 p50/p90/p99, zoo3 p50/p90/p99, per-host CPU, 5-host-avg CPU.

## Open issues surfaced

1. **jp-raft-* collapse at N=100+** — the rule_raft mode hits a rapid latency cliff that the adaptive throttle's CPU-based cutoff (added today at 80 % leader CPU, `src/deptran/rule/coordinator.cc`) didn't prevent. N=100 zoo2 latency data is dropped entirely (`zoo2_p50=0`) — likely a client-side aggregation bug when zoo2 clients have pending commands at shutdown. The tuning still needs a tighter threshold and/or the client-aggregation fix.
2. **Stop criterion fragility** — baseline and stop both look at zoo2 p50 only. When zoo2 reports 0 (missing-data sentinel) at saturated N, the zoo2 clause doesn't trip and bisection runs on other zoo hosts' latencies. A future iteration of the sweep script should fall back to max-across-clients p50 when zoo2 is -1 or 0.
3. **naive_rpc and naive_fastpath** were not rerun under core-17 today. The 2026-04-19 results ([docs/naive_rpc_zoo2_saturation_2026-04-19.md](naive_rpc_zoo2_saturation_2026-04-19.md), [docs/naive_fastpath_2026-04-19.md](naive_fastpath_2026-04-19.md)) are still the reference. The core-17 rerun is a small follow-up if directly-comparable numbers are needed.

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
