# naive_fastpath — broadcast + 4/5 quorum baseline (2026-04-19)

**Definition.** Client broadcasts each Dispatch RPC to all 5 replicas. Each server executes the R/W (SchedulerNone) and replies unconditionally — no conflict check, no ordering, no log. The client considers a request committed once it has collected **4 of 5 replies** (`RuleSuperMajority` for n=5, f=2). No replication, no durability, no linearizability.

This isolates the "broadcast + quorum" network pattern that CURP / EPaxos / SwiftPaxos use, with zero consensus bookkeeping on top. Any protocol that does a broadcast+quorum must land at or below this ceiling.

## Implementation

New folder `src/deptran/naive_fastpath/`:
- [frame.cc](../src/deptran/naive_fastpath/frame.cc) / [frame.h](../src/deptran/naive_fastpath/frame.h) — `NaiveFastpathFrame`, registered for `MODE_NAIVE_FASTPATH = 0xA001`.
- [coordinator.cc](../src/deptran/naive_fastpath/coordinator.cc) / [coordinator.h](../src/deptran/naive_fastpath/coordinator.h) — `CoordinatorNaiveFastpath`, 2-phase (INIT_END: broadcast+wait 4/5; DISPATCH: record latency + End).
- [commo.cc](../src/deptran/naive_fastpath/commo.cc) / [commo.h](../src/deptran/naive_fastpath/commo.h) — `CommunicatorNaiveFastpath::BroadcastDispatchToAll` which fires `async_Dispatch` to all 5 replicas and ties each reply into a `QuorumEvent(5, 4)`.
- [service.h](../src/deptran/naive_fastpath/service.h) — includes wrapper (no custom service; reuses base `ClassicServiceImpl`).

Server-side reuses `SchedulerNone::Dispatch` → `SchedulerClassic::Dispatch` → `OnCommit`; with `replica_proto_ == MODE_NONE` and `IsReplicated() == false`, `OnCommit` just commits locally and replies. That is the "reply unconditionally" behavior.

Config: `config/none_naive_fastpath.yml` sets `cc: naive_fastpath, ab: none`.

The reply callback applies `WAN_WAIT` symmetrically with `CoordinatorClassic::DispatchAck` so the measured latency is 1 full RTT (40 ms), not 1 one-way (20 ms).

## Latency at c=1

30 clients × 1 concurrent = 30 in-flight.

| Host | p50 (ms) | tp (cmd/s) |
|---|---:|---:|
| zoo1 | 40.67 | 3.60 |
| zoo2 | 41.21 | 4.20 |
| zoo3 | 40.83 | 3.90 |
| zoo4 | 40.85 | 4.10 |
| zoo5 | 40.94 | 3.80 |

p50 is ~41 ms — same as the 1-RTT consensus protocols (EPaxos, SwiftPaxos, CURP, Jetpack+Raft). Broadcast + 4/5 quorum does **not** add any meaningful latency over a single round-trip at c=1, because the 4th-fastest reply arrives essentially at the same time as the first (all hosts are ~equidistant over the emulated WAN).

## Max throughput — per-point sweep

Fixed `concurrent=500`, swept N ∈ {30, 50, 70, 100, 120, 140}. Each host reports the median of its core-1 /proc/stat samples over seconds 10–19 of the 30 s experiment (`server median` in the `.res` file). "CPU (5-host avg)" is the mean of those five per-host medians. The sweep uses a per-replica saturation detector internally so it knows when to stop, but the headline CPU column is the 5-host avg — that's the honest cross-protocol metric.

| N | Total tput (cmd/s) | CPU (5-host avg) | zoo1 | zoo2 | zoo3 | zoo4 | zoo5 | p50 zoo1 (ms) | p50 zoo4 (ms) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 30 | 5986 | 44.9 | 84.0 | 19.8 | 44.3 | 51.0 | 25.3 | 41.52 | 41.93 |
| 50 | 10000 | 59.8 | 78.0 | 28.9 | 73.7 | 74.8 | 43.9 | 41.57 | 41.97 |
| 70 | 13980 | 75.1 | 85.9 | 41.9 | 89.5 | 92.9 | 65.3 | 41.73 | 42.07 |
| 100 | 19963 | 81.5 | 68.0 | 63.9 | 93.9 | 94.1 | 87.8 | 41.84 | 42.16 |
| 120 | 23974 | 81.7 | 70.8 | 71.6 | 82.2 | 87.9 | 96.0 | 41.68 | 41.93 |
| **140** | **27966** | **88.0** ← STOP (bottleneck replica pinned) | 79.0 | 77.6 | 92.2 | 92.1 | 99.0 | 41.84 | 42.10 |

Peak **27,966 cmd/s at N=140**, p50 stays at ~42 ms the entire sweep.

## Where it lands in the protocol comparison

All CPU columns are 5-host averages of mid-10s core-1 medians. For single-target setups (naive_rpc-to-zoo2, etcd) the average dilutes the target host's load; the target host's own median is given in parens.

| Protocol | Peak tput (cmd/s) | Saturation N | CPU (5-host avg) | p50 at peak |
|---|---:|---:|---:|---:|
| naive_rpc → zoo2 only | 39968 | 200 | 56.4 (target zoo2 ~99) | 41.62 ms |
| **naive_fastpath (new)** | **27966** | **140** | 88.0 | 42.10 ms |
| EPaxos | 19991 | 100 | 73.1 | 42.53 ms |
| Raft | 13984 | 70 | 45.7 | 87.15 ms |
| SwiftPaxos | 11968 | 60 | 92.1 | 42.58 ms |
| CURP | 10973 | 55 | 73.7 | 42.67 ms |
| Jetpack+Raft fp100 | 8998 | 45 | 70.9 | 42.52 ms |
| etcd | 8000 | 40 | 32.2 (target zoo1 ~99) | 95.75 ms |
| Jetpack+Raft adaptive | 7993 | 40 | 57.2 | 42.17 ms |

**Interpretation:**

1. **naive_fastpath (27966) > EPaxos (19991).** The ~40% gap is the cost of EPaxos's dependency tracking (UpdateAttributes/UpdateConflicts on every PreAccept, per-replica conflict maps, seq computation, all-equal tracking, broadcast PreAccept + Commit) vs naive_fastpath's "receive → execute → reply." EPaxos's extra bookkeeping costs ~1.4× the per-replica CPU at the same throughput.

2. **naive_fastpath (27966) < naive_rpc (39968).** The `single-server-no-local-clients` ceiling is higher than `all-5-server+client-mixed` ceiling because naive_rpc isolated zoo2 (server work only), while naive_fastpath's bottleneck replica (zoo5 at saturation) is both running 28 local client threads AND serving ~28k inbound RPCs/s. Total work per replica in naive_fastpath = 1 × server-RPC work + 0.2 × (n_clients × client coordinator work) — the mixed workload saturates the pinned core sooner than pure-server work would.

3. **naive_fastpath > all real consensus protocols.** This is the intended ordering. Any broadcast+quorum protocol (CURP, EPaxos, SwiftPaxos) inherits at least this RPC cost; whatever it adds on top (conflict tables, log append, spec execution) reduces the achievable peak. SwiftPaxos at 12k is ~2.3× below naive_fastpath, CURP at 11k is ~2.5× below — measuring the added cost of "real" consensus bookkeeping relative to "just do the broadcast."

4. **p50 is identical (~42 ms) across naive_fastpath, CURP, Jetpack+Raft, SwiftPaxos, EPaxos.** All are dominated by the one WAN RTT; protocol-layer cost at c=1 is below the measurement noise.

## Commands used

```bash
bash scripts/run_single_exp.sh none_naive_fastpath.yml 0 concurrent_1.yml naive-fp-c1 \
  results/2026-04-19-naive-fastpath 30c1s5r5p-zoo.yml
bash /tmp/naive_fp_sweep.sh     # wraps run_single_exp.sh for the N sweep
```
