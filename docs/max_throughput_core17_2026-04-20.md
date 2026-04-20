# Max-Throughput Core-17 Sweep — 2026-04-20

Applies the canonical setting in [docs/max_throughput_experiment_setting.md](max_throughput_experiment_setting.md): server thread pinned to **core 17**, leader-routing protocols placed at zoo2, clients uniformly distributed, N=1 baseline co-located with the leader, adaptive sweep (N=1, 50, 100, extend/bisect) with stop at `zoo2 p50 > 2 × baseline`. Headline CPU number is the avg across the 5 hosts' mid-10 s core-17 means (not max-across-hosts).

All result dirs: `results/2026-04-20-<proto>-core17/` with per-N `.res`, `cpustat.txt`, and `SETTING.md` snapshots. Driver: [scripts/run_tier1_batch.sh](../scripts/run_tier1_batch.sh) + [scripts/run_adaptive_sweep.sh](../scripts/run_adaptive_sweep.sh).

## Peak per protocol

Ranked by peak `cmd/s`.

| Protocol | Peak (cmd/s) | N | zoo2 p50 (ms) | zoo2 p90 | zoo2 p99 | zoo3 p50 | zoo1 cpu | zoo2 cpu | zoo3 cpu | zoo4 cpu | zoo5 cpu | **avg cpu** |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **naive_epaxos** | **44 284** | 231 | 122.9 | 180.2 | 280.7 | 152.1 | 95.5 | 88.7 | 96.8 | 98.1 | 99.5 | **95.7** |
| **epaxos** | **27 363** | 137 | 78.2 | 236.7 | 546.9 | 78.8 | 99.5 | 18.2 | 52.5 | 57.7 | 25.5 | **50.7** |
| **naive_raft** | **18 004** | 90 | 87.5 | 153.1 | 217.2 | 88.0 | 23.1 | 99.8 | 48.6 | 59.6 | 29.7 | **52.2** |
| **swiftpaxos** | **16 788** | 84 | 43.3 | 44.5 | 68.5 | 43.5 | 99.9 | 69.6 | 93.9 | 93.8 | 83.0 | **88.0** |
| **raft** | **15 331** | 81 | 96.4 | 571.4 | 849.6 | 96.6 | 96.1 | 13.7 | 37.5 | 52.8 | 23.1 | **44.6** |
| **etcd** | **13 002** | 65 | 89.0 | 98.1 | 118.0 | 89.5 | 99.9 | 5.7 | 14.6 | 16.5 | 7.4 | **28.8** |
| **jp-raft-fp100** | 9 990 | 50 | 42.3 | 46.9 | 83.6 | 42.7 | 91.1 | 45.1 | 84.9 | 88.3 | 56.3 | **73.2** |
| **jp-raft-adaptive** | 9 955 | 50 | 43.4 | 61.6 | 194.5 | 43.7 | 40.9 | 46.6 | 84.0 | 99.1 | 58.1 | **65.7** |

Notes on saturation-detection quirks the script exposed:

- **jp-raft-fp100 and jp-raft-adaptive peaks are under-reported.** Both collapsed between N=50 and N=100: at N=100 zoo2 produced no latency data (`zoo2_p50=0` from missing client-side aggregation on that host, see below), so the stop criterion didn't trip on the zoo2 clause. Bisection rows from N=106 onward all stopped because zoo3/zoo4 latencies were in the 1–3 s range. The N=50 row is therefore the last clean point; the "true" peak likely sits somewhere in [50, 100] and needs a denser sweep to locate.
- **etcd peak is still zoo1-bound.** Only zoo1 opens the etcd connection pool (per `src/deptran/etcd/server.h:51`, only `locale_id=0` creates connections), so the 5-host avg (28.8 %) badly under-reports what's happening on zoo1 (99.9 %). The real bottleneck is zoo1's single core.
- **raft zoo1 is the leader core** — 96 % there is the saturation signal, not the low 5-host avg.

## Peak ordering

**naive_epaxos > epaxos > naive_raft > swiftpaxos > raft > etcd > jp-raft-fp100 ≈ jp-raft-adaptive.**

Two notable clusters:

1. **Distributed-leader protocols dominate.** naive_epaxos (44 k), epaxos (27 k), and naive_raft (18 k) distribute work across all 5 replicas and hit 44 k+ peaks because no single replica pins until much later in the sweep. naive_epaxos's peak is **2.6 × naive_raft's** — the "per-site leader" design (every server is a leader for its own local clients) spreads write load evenly, while naive_raft concentrates all writes on zoo2.
2. **Fixed-leader protocols pin early.** raft, etcd, and (approximately) jp-raft-* all hit their ceiling when zoo1 or zoo2 reaches ~100 % core-17 CPU. That's typical of any protocol where a single replica does an outsized share of work.

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
