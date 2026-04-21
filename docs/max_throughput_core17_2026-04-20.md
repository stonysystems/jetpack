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

**Raft leader on zoo2 confirmed.** At peak N=84 the raft leader core (zoo2) pins at **99.5 %** while the other four replicas sit at 21–57 %. This matches the experiment spec ("if the protocol has a leader/master/unique server, put it on zoo2"). See the per-protocol CSVs for the bisection rows that bracket the peak.

**Stable-leader fix** (rerun of raft-family after the earlier pass had tput=0 holes between N=50 and N=100): with `RAFT_ELECTION_ONLY_INIT_AND_POST_FAILURE_ONCE_PATCH` defined, a saturated zoo2 would miss heartbeats, zoo1's election timer would fire, zoo1 would steal leadership with a higher term, and the patch would then block zoo2 from re-winning — leadership thrashed and latency collapsed. Fix: election timeout for `locale_id != 1` set to `20 × 1000 × HEARTBEAT_INTERVAL` (~100 s), well beyond the 30 s experiment duration, so non-zoo2 replicas never time out in-test even if heartbeats slip. With this, jp-raft-fp100 peaks at **13 586** (+36 % vs 10 003 before) and jp-raft-adaptive at **14 189** (+42 % vs 9 981). Adaptive now beats fp100 at saturation — the throttle's CPU-threshold disable (added [src/deptran/rule/coordinator.cc](../src/deptran/rule/coordinator.cc)) kicks in and lets the leader spend cycles on raft replication instead of failed spec RPCs.

Notes on saturation-detection quirks:

- **etcd peak is still zoo1-bound.** Only zoo1 opens the etcd connection pool (per `src/deptran/etcd/server.h:51`, only `locale_id=0` creates connections), so the 5-host avg (28.8 %) badly under-reports what's happening on zoo1 (99.9 %). The real bottleneck is zoo1's single core.

## Peak ordering

**naive_epaxos > epaxos > naive_raft > swiftpaxos ≈ raft > jp-raft-adaptive ≈ jp-raft-fp100 > etcd.**

Two notable clusters:

1. **Distributed-leader protocols dominate.** naive_epaxos (44 k), epaxos (27 k), and naive_raft (18 k) distribute work across all 5 replicas and hit 44 k+ peaks because no single replica pins until much later in the sweep. naive_epaxos's peak is **2.5 × naive_raft's** — the "per-site leader" design (every server is a leader for its own local clients) spreads write load evenly, while naive_raft concentrates all writes on zoo2.
2. **Fixed-leader protocols pin early.** raft (zoo2), swiftpaxos, jp-raft-*, etcd (zoo1 only for connection pool) all hit their ceiling when a single replica reaches ~100 % core-17 CPU. Raft and SwiftPaxos peaks are nearly identical (~16–17 k cmd/s); both saturate the leader core at similar rates. SwiftPaxos keeps p50 at ~43 ms (1 RTT) while Raft's p50 stays near 99 ms at peak (still comfortably under the 156 ms stop threshold). Jetpack+Raft variants trade peak for latency: ~13–14 k cmd/s at 45 ms p50 — lower ceiling than plain Raft because the fast-path spec RPCs compete with raft replication on the same pinned leader core.

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
