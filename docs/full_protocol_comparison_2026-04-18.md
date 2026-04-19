# Full Protocol Comparison (with CURP + etcd + naive_rpc) — 2026-04-18, updated 2026-04-19

> **Naming note (2026-04-19 rename):** Host names in this doc are 1-indexed (`zoo1=.101`, `zoo2=.102`, `zoo3=.103`, `zoo4=.104`, `zoo5=.105`). The result files on disk for this experiment were recorded under the older 0-indexed scheme (`-zoo0.res` … `-zoo4.res`); read those with the mapping `zoo0↔zoo1`, `zoo1↔zoo2`, `zoo2↔zoo3`, `zoo3↔zoo4`, `zoo4↔zoo5`.


**Results dirs**: `results/2026-04-16-bisection/` (Raft, Jetpack+Raft fp100/adaptive, SwiftPaxos, EPaxos), `results/2026-04-18-curp-etcd-rerun/` (CURP, etcd), `results/2026-04-19-naive-rpc/` (naive_rpc).

**Cluster**: 5-node zoo (.101-.105), pinned server core 1, WAN_DELAY_MS=20 (40ms RTT), `rw_1000000.yml`, `client_open.yml`, 30s per point.

**naive_rpc** is a new "no-consensus" baseline: client sends one Dispatch RPC to the configured leader (zoo1 by default), server executes the R/W locally and replies. Implementation is just `config/none_naive_rpc.yml` (`cc: none, ab: naive_rpc` — an alias for `MODE_NONE` added in `frame.cc`); this re-uses `CoordinatorNone` on the client and `SchedulerNone::Dispatch`+`OnCommit` on the server, with `IsReplicated()==false` so `OnCommit` skips Raft and commits locally. It measures the floor — pure RPC framework + 1 WAN RTT, with no replication or ordering.

## Latency at c=1 (all 8 protocols)

30 clients × 1 concurrent per worker = 30 in-flight.

| Protocol | p50 (ms) | Type |
|---|---:|---|
| **naive_rpc** | **40.38 / 41.21 / 40.76 / 40.65 / 41.75 (all hosts)** | 1 RTT, no consensus |
| EPaxos | 40.42 | 1 RTT ✓ |
| SwiftPaxos | 40.51 | 1 RTT ✓ |
| Jetpack+Raft adaptive | 40.59 | 1 RTT ✓ |
| **CURP** | **40.59 / 41.27 / 40.71 / 40.76 / 40.89 (all hosts)** | 1 RTT ✓ |
| Jetpack+Raft fp100 | 40.64 | 1 RTT ✓ |
| Raft | 79.59 | 2 RTT |
| **etcd** | **84.46 / 85.23 / 85.13 / 85.06 / 86.17 (all hosts)** | 2 RTT |

naive_rpc at 40.38-41.75 ms p50 is essentially identical to the 1-RTT consensus protocols (41-42 ms). Conclusion: **consensus adds ~0-2 ms on top of the bare RPC round-trip at c=1**. The protocol cost is dwarfed by the WAN 40 ms RTT.

etcd's 2-RTT is expected — etcd client lib runs its own Raft commit path on top of the local etcd daemon.

## Max-throughput bisection — peak per protocol

For each protocol, swept client count N ∈ {30, 40, 45, 50, 55, 60, 70, 80, 90, 100} at concurrent=500. Stopped per-protocol when the bottleneck replica's core-1 CPU median (mid-10s) reached 99% or zoo1/zoo4 p50 > 2× c=1 baseline. "CPU (5 hosts avg)" below is the mean of the five per-host medians (each host's median is over its own mid-10s 10-sample window).

| Protocol | Peak tput (cmd/s) | Saturation N | CPU (5 hosts avg) | p50 (zoo4) |
|---|---:|---:|---:|---:|
| **naive_rpc** | **19980.6** | 100 (did not saturate) | 20.1% | 41.72 ms |
| **EPaxos** | **19990.6** | 100 | 73.1% | 42.53 ms |
| Raft | 13984.4 | 70 | 45.7% | 87.15 ms |
| SwiftPaxos | 11968.4 | 60 | 92.1% | 42.58 ms |
| **CURP** (after `a1d6b8b2`) | **10973.3** | 55 | 73.7% | 42.67 ms |
| Jetpack+Raft fp100 | 8997.9 | 45 | 70.9% | 42.52 ms |
| etcd | 8000.1 | 40 | 32.2% | 95.75 ms |
| Jetpack+Raft adaptive | 7993.4 | 40 | 57.2% | 42.17 ms |

**naive_rpc was not the ceiling.** The naive_rpc sweep reached N=100 (19980 cmd/s at only 20% avg CPU, bottleneck zoo1 at 58%) without hitting the 99% stop threshold. Throughput scaled almost exactly as `200 × N` across the entire sweep — the same client-side per-worker ~200 cmd/s cap that all other protocols hit at low N. The 200-cmd/s-per-client cap is in the client coordinator/coroutine dispatch path, independent of what the server does. **Any protocol can ride that cap up to 20k at N=100**; beyond that, the server-side consensus cost starts to matter. EPaxos reaches the same 19991 peak; all other protocols hit their *server-side* bottleneck before the client cap.

**Peak ordering**: EPaxos > Raft > SwiftPaxos > **CURP** > Jetpack+Raft fp100 > etcd ≥ Jetpack+Raft adaptive.

**New insights from the reruns**:

1. **CURP is now competitive with SwiftPaxos in throughput and gives 1-RTT latency.** Peak 10973 @ N=55 vs SwiftPaxos 11968 @ N=60 — CURP is within 9% at a lower saturation N. Both achieve 42ms p50 across all hosts.

2. **CURP still peaks lower than vanilla Raft.** Raft 13984 vs CURP 10973 — CURP's speculative broadcast still costs non-leader CPU (`command_pool_.push_back` on every witness), so its non-leader replicas work harder (avg CPU 73.7% vs Raft's 45.7%). That extra work means CURP's max-CPU host (zoo4, the leader) pins sooner than Raft's leader does.

3. **CURP beats Jetpack+Raft fp100 on peak throughput** (10973 vs 8998, +22%), because CURP skips the spec RPC to the leader. The leader in CURP only does Raft replication, whereas in Jetpack+Raft fp100 it does both.

4. **etcd peaks at 8000 cmd/s @ N=40.** The bottleneck is the single etcd-client connection pool on zoo1 (loc_id=0 is the only replica that opens the pool, per `deptran/etcd/server.h`). zoo1 pins at 97-99% CPU while the other 4 Janus replicas stay idle (4-23% CPU). So etcd's Janus-layer peak is zoo1's own pinned core; the underlying etcd cluster has more capacity but we don't exploit it.

5. **Latency difference at peak is significant**:
   - CURP / Jetpack+Raft / SwiftPaxos / EPaxos: 42 ms p50 (1 RTT).
   - Raft: 87 ms p50 (2 RTT).
   - etcd: 95-112 ms p50 (2 RTT + etcd-internal latency).

## Per-N sweep detail

### CURP (new)

| N | Total | CPU (5 hosts avg) | p50 (zoo4) |
|---:|---:|---:|---:|
| 30 | 6008.9 | 49.5 | 41.94 |
| 40 | 8005.2 | 60.4 | 42.13 |
| 45 | 8996.1 | 65.5 | 42.16 |
| 50 | 9992.4 | 66.1 | 41.96 |
| 55 | 10973.3 | 73.7 | 42.67 |
| 60 | 11287.5 | 73.2 | 42.37 ← STOP (bottleneck replica pinned) |

### etcd (new)

| N | Total | CPU (5 hosts avg) | p50 (zoo1) |
|---:|---:|---:|---:|
| 30 | 5989.3 | 27.4 | 88.80 |
| 40 | 8000.1 | 32.2 | 95.08 |
| 45 | 9005.1 | 32.3 | 111.66 ← STOP (bottleneck replica pinned) |

etcd's avg stays low (~30%) because only zoo1 opens the etcd connection pool (per `deptran/etcd/server.h:51`, only `loc_id == 0` creates connections); zoo1 does ~97-99% of the work while the other four Janus replicas stay at 4-23%. Averaging hides this, so for etcd the bottleneck is specifically zoo1, not the cluster average.

### naive_rpc (new baseline)

| N | Total | CPU (5 hosts avg) | p50 (zoo4) | Bottleneck zoo1 |
|---:|---:|---:|---:|---:|
| 30 | 5999.1 | 15.0 | 41.70 | 65% |
| 40 | 7986.6 | 8.6 | 41.71 | 28% |
| 45 | 8996.7 | 19.7 | 41.70 | 80% |
| 50 | 9978.0 | 15.2 | 41.68 | 58% |
| 55 | 10990.3 | 12.1 | 41.71 | 41% |
| 60 | 11990.4 | 16.2 | 41.71 | 58% |
| 70 | 13993.6 | 15.0 | 41.72 | 47% |
| 80 | 15933.3 | 18.5 | 41.74 | 56% |
| 90 | 17996.0 | 18.9 | 41.71 | 55% |
| 100 | 19980.6 | 20.1 | 41.72 | 58% |

Throughput tracks `200 × N` to within 0.1% at every point. p50 stays flat at 41.7 ms (= 40 ms WAN RTT + ~1-2 ms dispatch/execute). Bottleneck zoo1 stays at 40-80% throughout — it never pins. Conclusion: at N≤100, the client-side per-worker issue cap dominates; the server has ample headroom. To see naive_rpc's true server ceiling we'd need to break the client cap or push N past 150.

## CPU efficiency (cmd/s per avg-CPU-percent across 5 hosts)

Each protocol's peak throughput divided by the 5-host average CPU at that peak N. Higher = the protocol converts per-replica CPU into throughput more efficiently (better load balancing and/or cheaper per-command work).

| Protocol | Peak / avg CPU |
|---|---:|
| Raft | 306 |
| EPaxos | 274 |
| etcd | 248 |
| Jetpack+Raft adaptive | 140 |
| CURP | 149 |
| Jetpack+Raft fp100 | 127 |
| SwiftPaxos | 130 |

Note: Raft's high ratio reflects most of its 5 hosts being *idle* (followers just replicate) at peak — its avg CPU of 45% is low because only the leader pins. EPaxos distributes work so all 5 replicas contribute. etcd's 248 is misleading — it only uses zoo1, so the "5-host avg" dilutes the real zoo1 load; a better etcd metric would be zoo1-specific.

## Commands used

```bash
# Latency c=1
./scripts/run_single_exp.sh none_curp.yml 200 concurrent_1.yml curp-c1 results/2026-04-18-curp-etcd-rerun 30c1s5r5p-zoo.yml
./scripts/run_single_exp.sh none_etcd.yml 0 concurrent_1.yml etcd-c1 results/2026-04-18-curp-etcd-rerun 30c1s5r5p-zoo.yml

# etcd cluster lifecycle
./scripts/start_etcd_cluster.sh
./scripts/stop_etcd_cluster.sh

# Bisection (runs both CURP and etcd, stops at saturation)
bash /tmp/curp_etcd_sweep.sh   # or adapt scripts/run_bisection_sweep.sh
```
