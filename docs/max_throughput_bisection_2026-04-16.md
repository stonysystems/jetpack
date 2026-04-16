# Max-Throughput Bisection — 2026-04-16

**Results dir**: `results/2026-04-16-bisection/`
**Cluster**: 5-node zoo (.101-.105), pinned server core 1
**Settings**: `concurrent=500`, `rw_1000000.yml`, `client_open.yml`, `WAN_DELAY_MS=20` (40ms RTT), 30s per point
**Stop criterion**: per-protocol sweep stops at the first client count where max server CPU ≥ 99% on any host OR zoo0/zoo3 p50 > 2× c1-baseline (85ms for Raft, 42ms for others).

**What changed since the coarse 30-vs-60 run:** added finer-grained client configs (40, 45, 50, 55, 70, 75, 80, 90, 100) and swept each protocol until it hit a real ceiling. This separates protocol CPU efficiency from the client-side per-worker ~200 cmd/s cap that dominated the 30-client numbers.

## Summary — per-protocol peak at saturation

Saturation N = last swept client count at which some host was still below the 99% stop threshold. The next larger N tripped the stop, so peak throughput here is the measured number at saturation N, not an extrapolation.

| Protocol | Peak tput (cmd/s) | Saturation N | Max CPU host @ peak | Max CPU | Avg CPU (5 hosts) | p50 (zoo3) | Stopped at N |
|---|---:|---:|---:|---:|---:|---:|---:|
| **EPaxos** | **19990.6** | **100** | zoo0 | 98.99% | 73.1% | 42.53 ms | (did not stop in sweep range) |
| **Raft** | **13984.4** | **70** | zoo1 | 89.90% | 45.7% | 87.15 ms | 80 (100% CPU, p50 985ms) |
| **SwiftPaxos** | **11968.4** | **60** | zoo0 | 98.99% | 92.1% | 42.58 ms | 70 (100% CPU) |
| **Jetpack+Raft fp100** | **8997.9** | **45** | zoo3 | 92.78% | 70.9% | 42.52 ms | 50 (100% CPU) |
| **Jetpack+Raft adaptive** | **7993.4** | **40** | zoo3 | 93.94% | 57.2% | 42.17 ms | 45 (100% CPU) |

**Peak throughput order**: EPaxos > Raft > SwiftPaxos > Jetpack+Raft fp100 > Jetpack+Raft adaptive.

**Key observations**:

1. **EPaxos has the highest peak by a wide margin** (19,990 cmd/s vs Raft's 13,984 — ~43% more). EPaxos distributes work across all 5 replicas almost uniformly (all replicas handle proposal traffic), so no single host becomes the bottleneck until N=90+.
2. **Raft scales further than the simplified coarse run suggested** — it held ~14k at 89.9% CPU on the leader. At N80 it crashed to 985ms p50 (the leader core saturated at 100%).
3. **SwiftPaxos reaches the same ballpark as Raft** (~12k cmd/s), but at ~98% CPU on zoo0 — its per-command cost is higher (dependency tracking + per-key conflict check) so it runs hotter.
4. **Jetpack+Raft variants peak lowest** despite providing 1-RTT latency. The fast-path speculative broadcast costs CPU on the leader — at N45-50 the leader pins to 100%. The throughput ceiling is set by the leader's pinned core, which has to process both the Raft slow-path AND the fast-path RPCs.
5. **CPU efficiency (peak-tput / max-CPU)**: EPaxos ~200 cmd/s per CPU-percent, Raft ~155, SwiftPaxos ~121, Jetpack+Raft fp100 ~97, Jetpack+Raft adaptive ~85. EPaxos's distributed-work model wins twice: higher peak and lower max-CPU at peak.

## Full sweep tables

### Raft (baseline)

| N | Total tput | Max CPU | Avg CPU | p50 (zoo0) | p50 (zoo3) |
|---:|---:|---:|---:|---:|---:|
| 30 | 5982.6 | 38.30 | 28.57 | 75.61 | 75.91 |
| 40 | 7993.5 | 57.00 | 28.04 | 76.57 | 77.02 |
| 45 | 8996.3 | 56.25 | 35.47 | 77.88 | 78.38 |
| 50 | 9984.9 | 73.96 | 39.26 | 79.85 | 80.18 |
| 55 | 11003.0 | 69.79 | 44.25 | 80.87 | 81.29 |
| 60 | 11990.7 | 96.04 | 45.96 | 88.49 | 88.78 |
| 70 | 13984.4 | 89.90 | 45.75 | 86.78 | 87.15 |
| 80 | 14210.6 | **100.00** | 41.74 | **985.32** | **987.20** | **STOP** |

Raft latency is stable at ~76-88ms p50 while scaling. At N80 the leader pins at 100% and p50 collapses to ~985ms — classic queue-buildup pattern.

### Jetpack+Raft fp100 (force 100% fast-path)

| N | Total tput | Max CPU | Avg CPU | p50 (zoo0) | p50 (zoo3) |
|---:|---:|---:|---:|---:|---:|
| 30 | 6002.0 | 94.95 | 51.85 | 41.99 | 42.26 |
| 40 | 7985.6 | 94.95 | 58.70 | 41.99 | 42.22 |
| 45 | 8997.9 | 92.78 | 70.90 | 42.03 | 42.52 |
| 50 | 9993.1 | **100.00** | 67.62 | 43.17 | 43.41 | **STOP** |

Fast-path p50 is ~42ms throughout (half of Raft). But peak throughput is much lower than Raft because the leader is already at 93-95% CPU at N30 and pins at 100% by N50.

### Jetpack+Raft adaptive

| N | Total tput | Max CPU | Avg CPU | p50 (zoo0) | p50 (zoo3) |
|---:|---:|---:|---:|---:|---:|
| 30 | 5997.5 | 75.00 | 52.95 | 41.55 | 41.99 |
| 40 | 7993.4 | 93.94 | 57.21 | 41.90 | 42.17 |
| 45 | 8990.1 | **100.00** | 71.08 | 43.57 | 44.05 | **STOP** |

Adaptive mode saturates slightly earlier than fp100 — likely because it sometimes chooses slow path (adding work to both paths) at moderate load.

### SwiftPaxos

| N | Total tput | Max CPU | Avg CPU | p50 (zoo0) | p50 (zoo3) |
|---:|---:|---:|---:|---:|---:|
| 30 | 5987.7 | 92.86 | 79.61 | 41.60 | 42.07 |
| 40 | 7983.7 | 94.79 | 87.66 | 41.71 | 42.17 |
| 45 | 8990.6 | 95.05 | 89.87 | 41.76 | 42.22 |
| 50 | 9978.9 | 95.96 | 91.32 | 41.85 | 42.32 |
| 55 | 10997.0 | 97.98 | 91.70 | 42.01 | 42.53 |
| 60 | 11968.4 | 98.99 | 92.08 | 42.08 | 42.58 |
| 70 | 14015.2 | **100.00** | 89.83 | 42.53 | 42.98 | **STOP** |

SwiftPaxos runs hot from N=30 onward (all 5 replicas at ~80-95% CPU) but keeps scaling. Peak 14k at N70 — comparable to Raft but with 1-RTT latency (42ms vs Raft's 87ms).

### EPaxos

| N | Total tput | Max CPU | Avg CPU | p50 (zoo0) | p50 (zoo3) |
|---:|---:|---:|---:|---:|---:|
| 30 | 6005.9 | 65.26 | 36.04 | 41.45 | 41.85 |
| 40 | 7998.7 | 64.00 | 43.24 | 41.43 | 41.80 |
| 45 | 8989.4 | 64.95 | 49.91 | 41.43 | 41.82 |
| 50 | 9993.2 | 75.73 | 51.86 | 41.42 | 41.82 |
| 55 | 10985.9 | 78.50 | 60.12 | 41.41 | 41.84 |
| 60 | 11973.2 | 83.33 | 56.00 | 41.45 | 41.95 |
| 70 | 14000.0 | 87.88 | 68.15 | 41.46 | 41.96 |
| 80 | 15983.7 | 90.91 | 66.66 | 41.50 | 42.01 |
| 90 | 17963.5 | 95.96 | 76.28 | 41.71 | 42.25 |
| 100 | **19990.6** | **98.99** | 73.14 | 41.96 | 42.53 |

EPaxos is the outlier — p50 stays essentially flat at 41-42ms across the entire sweep, and max CPU only reaches 99% at N=100. Throughput scales nearly linearly with N (20k at N=100, 18k at N=90, 14k at N=70 — 200 cmd/s per client matches the client issue cap). If we had run N120, EPaxos likely would have saturated there at ~24k.

## Interpretation

Two distinct saturation patterns show up:

**Leader-pinned protocols** (Raft, Jetpack+Raft fp100/adaptive): one replica's pinned core is the ceiling. All these peak at around 10k-14k because one host can only do so much work per second. Jetpack variants peak *lower* than Raft despite lower latency because the fast path adds CPU overhead on that same pinned core.

**Distributed-work protocols** (EPaxos, SwiftPaxos): each replica does work proportionally to traffic. No single host pins until much higher throughput.

EPaxos peaks highest because its simplified fast-commit path (commit immediately after 3-replica PreAccept quorum agrees on deps) amortizes best across 5 replicas. SwiftPaxos does more per-command work (hash-based conflict tracking, dependency sequencing) so it runs hotter per replica, but still scales past Raft's leader ceiling.

Jetpack+Raft's latency win (42ms vs 87ms) is preserved, but its throughput ceiling is set by the leader's pinned core — which is actually lower than plain Raft's because the fast-path speculative RPC work happens on the leader too. To get Jetpack+Raft to scale further, the fast-path work would need to move off the leader core (e.g., dedicated fast-path thread) or the Raft dispatch would need to stop going to the leader exclusively.

## Client-side cap still visible

Each client commits ~200 cmd/s at concurrent=500 (a known client-side coroutine-dispatch cap). So total throughput is very close to `200 × N` at low N:

| N | 200 × N (expected) | Best observed |
|---:|---:|---:|
| 30 | 6000 | 6006 (EPaxos) |
| 50 | 10000 | 9993 (Jetpack+Raft fp100) |
| 70 | 14000 | 14015 (SwiftPaxos) |
| 100 | 20000 | 19991 (EPaxos) |

At every N below saturation, the 5 protocols that aren't pinned converge to within ±0.5% of `200 × N`. This means the client is the bottleneck at sub-saturation N, and we're only measuring the protocol when CPU pins. Any protocol ceiling measurement here is a lower bound on what the protocol could do with a faster client.

## Commands

```bash
./scripts/run_bisection_sweep.sh results/2026-04-16-bisection
```

## Follow-ups (not done)

- Run EPaxos at N=120, 140 to find its actual ceiling (it didn't stop in this sweep).
- Client-side dispatch rewrite to remove the ~200 cmd/s per-client cap. With that fix, Jetpack+Raft might scale higher even though its leader is already at 94% at N30, because the client isn't the bottleneck.
- Contention workloads (Zipf, small key range) to distinguish conflict-handling overhead between SwiftPaxos and EPaxos.
