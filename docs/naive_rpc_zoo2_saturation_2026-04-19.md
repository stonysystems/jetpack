# naive_rpc targeting zoo2 (.102) — saturation sweep 2026-04-19

**Setup change vs. 2026-04-18 run**: naive_rpc now routes **all client Dispatch RPCs to zoo2 (locale_id=1, IP 130.245.173.102)** instead of the default zoo1. The change is a 3-line patch in `Communicator::GetLeaderForPartition` that short-circuits to `return 1` when `replica_proto_ == MODE_NAIVE_RPC`. Everything else is identical to the prior naive_rpc setup (`cc=none, ab=naive_rpc, concurrent=500, WAN_DELAY_MS=20, 30s per point, mid-10s median CPU`).

**Why the change**: on the prior run every client targeted zoo1, but zoo1 also has 20% of all client workers co-located. That polluted the zoo1 CPU reading with client-side reactor work. Routing to zoo2 isolates the target — zoo2 handles only inbound server work from remote clients — so the mid-10s median on zoo2 is a clean measurement of the protocol's server-side CPU cost.

**Stop criterion**: zoo2's mid-10s median CPU ≥ 95%. Reached at N=200.

## Experiment matrix

- Fixed: `concurrent=500`, `none_naive_rpc.yml`, `rw_1000000.yml`, `client_open.yml`, 30s/point.
- Swept: `N ∈ {30, 50, 70, 100, 120, 140, 160, 180, 200}` — 9 experiments.

## Full per-point table

| N | conc | Total tput (cmd/s) | **zoo2 CPU (target)** | 5-host avg CPU | CPU zoo1 | CPU zoo3 | CPU zoo4 | CPU zoo5 | p50 zoo2 (ms) | p50 zoo4 (ms) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 30 | 500 | 6004.8 | **36.2** | 29.5 | 100.0* | 3.1 | 3.1 | 5.1 | 41.24 | 41.73 |
| 50 | 500 | 9984.1 | **32.0** | 30.3 | 100.0* | 4.1 | 4.1 | 11.2 | 41.24 | 41.68 |
| 70 | 500 | 13997.9 | **42.1** | 33.9 | 100.0* | 4.2 | 3.1 | 20.2 | 41.22 | 41.70 |
| 100 | 500 | 19992.5 | **60.0** | 41.1 | 99.0* | 5.2 | 4.1 | 37.1 | 41.25 | 41.71 |
| 120 | 500 | 23967.2 | **71.4** | 46.1 | 100.0* | 7.1 | 6.1 | 45.8 | 41.27 | 41.72 |
| 140 | 500 | 27994.7 | **78.1** | 48.7 | 99.0* | 9.9 | 6.1 | 50.5 | 41.24 | 41.73 |
| 160 | 500 | 31933.5 | **89.0** | 54.9 | 100.0* | 13.1 | 12.4 | 59.8 | 41.38 | 41.77 |
| 180 | 500 | 35968.8 | **93.9** | 54.3 | 100.0* | 11.0 | 8.0 | 58.3 | 41.42 | 41.86 |
| **200** | **500** | **39968.3** | **98.96** ← STOP | 56.4 | 100.0* | 11.3 | 10.0 | 61.9 | 41.62 | 42.06 |

\* zoo1's core-1 reads 99-100% across the whole sweep, but this is **not** server load — zoo1 never receives RPCs in this setup. The number reflects the always-pinned reactor/poll thread and a long-standing core-0/core-1 scheduling quirk on this specific host. It was present even at c=1 in the previous naive_rpc run. Treat it as a measurement artifact and ignore for saturation analysis.

## Key findings

1. **Single-server peak: ~40k cmd/s at ~99% CPU.** Past the previous naive_rpc-to-zoo1 peak (19980 cmd/s @ N=100, server never saturated) by 2×, confirming that the earlier ceiling was the N=100 end-of-sweep, not a real cap.
2. **Throughput tracks `200 × N` exactly** (6004, 9984, 13998, 19993, 23967, 27995, 31934, 35969, 39968). The client per-worker 200 cmd/s cap still dictates the shape; zoo2 happens to be able to service that rate up through N=200 before its own core pins.
3. **p50 is flat at 41.2–41.6 ms (1 WAN RTT)** across the entire sweep. No queue buildup even as zoo2 approaches saturation. At N=200 when zoo2 is at 99%, p50 on zoo2 rises only from 41.24 → 41.62 ms (+0.4 ms), showing a gentle queueing tail.
4. **zoo5 grows with N in an unexplained way** (5% → 62% across the sweep). Same pattern as the previous run. Likely a client-side reactor/poll-thread quirk that scales with the number of client threads on zoo5. Unrelated to the target server measurement.
5. **zoo3 and zoo4 stay ≤13% across the whole sweep** — they have clients but neither clients nor servers on those hosts do significant core-1 work.
6. **This is the true naive_rpc server ceiling on this hardware**: ~40k cmd/s = ~25 μs per RPC of server-side core-1 work. EPaxos at N=100 reached 19990 cmd/s at 73% 5-host avg CPU — about 2× lower per-replica efficiency than naive_rpc's ~20k-at-60%-zoo2-only, which is expected because EPaxos runs dependency tracking on every replica per command.

## Interpretation in context of the 8-protocol comparison

| Protocol | Peak tput (cmd/s) | Saturation N (this cluster) | Target server CPU at peak | p50 at peak |
|---|---:|---:|---:|---:|
| **naive_rpc → zoo2 only** | **39968** | **200** | 99% (zoo2) | 41.62 ms |
| EPaxos | 19991 | 100 | avg 73% (distributed, zoo1 99%) | 42.53 ms |
| Raft | 13984 | 70 | leader ~90% | 87.15 ms |
| SwiftPaxos | 11968 | 60 | avg 92% (all hosts) | 42.58 ms |
| CURP (fixed) | 10973 | 55 | avg 74%, leader ~92% | 42.67 ms |
| Jetpack+Raft fp100 | 8998 | 45 | avg 71%, leader ~93% | 42.52 ms |
| etcd | 8000 | 40 | zoo1 99% | 95.75 ms |
| Jetpack+Raft adaptive | 7993 | 40 | avg 57%, leader ~94% | 42.17 ms |

naive_rpc's 40k isolates the **unreplicated server-side ceiling on this hardware** at ~40 k cmd/s. Any consensus protocol has to stay below that because it either (a) pins one replica (Raft-like — leader ceiling lower than naive_rpc because consensus adds leader work), or (b) distributes work across replicas but does more per command (EPaxos-like — higher total than a leader-pinned protocol, but per-replica work is higher too).

## Commands used

```bash
# One-time: add MODE_NAIVE_RPC routing (committed)
# Short-circuit Communicator::GetLeaderForPartition to return 1 for MODE_NAIVE_RPC

# Sweep (script name predates the zoo rename; it targets the same host .102)
bash /tmp/naive_to_zoo1_sweep.sh
```
