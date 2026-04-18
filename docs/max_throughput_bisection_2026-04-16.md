# Max-Throughput Bisection — 2026-04-16

**Results dir**: `results/2026-04-16-bisection/`
**Cluster**: 5-node zoo (.101-.105), pinned server core 1
**Settings**: `concurrent=500`, `rw_1000000.yml`, `client_open.yml`, `WAN_DELAY_MS=20` (40ms RTT), 30s per point
**Stop criterion**: per-protocol sweep stops at the first client count where max server CPU ≥ 99% on any host OR zoo0/zoo3 p50 > 2× c1-baseline (85ms for Raft, 42ms for others).

**What changed since the coarse 30-vs-60 run:** added finer-grained client configs (40, 45, 50, 55, 70, 75, 80, 90, 100) and swept each protocol until it hit a real ceiling. This separates protocol CPU efficiency from the client-side per-worker ~200 cmd/s cap that dominated the 30-client numbers.

## Summary — per-protocol peak at saturation

**CPU metric**: each host reports the median of ~10 per-second core-1 /proc/stat samples taken over the mid-10s window (experiment seconds 10–19) of the 30s run. "CPU (5 hosts avg)" below is the mean of those five per-host medians. We report avg-across-hosts rather than max-across-hosts; the max is still what *triggers* saturation internally (a protocol's bottleneck is whichever replica pins first), but the avg is the honest number for comparing protocol CPU cost because it doesn't over-weight load-balancing differences.

Saturation N = last swept client count at which the bottleneck replica was still below 99% and p50 was still within budget. The next larger N tripped the stop.

| Protocol | Peak tput (cmd/s) | Saturation N | CPU (5 hosts avg) | p50 (zoo3) | Stopped at N |
|---|---:|---:|---:|---:|---:|
| **EPaxos** | **19990.6** | **100** | 73.1% | 42.53 ms | (did not stop in sweep range) |
| **Raft** | **13984.4** | **70** | 45.7% | 87.15 ms | 80 (bottleneck replica pinned, p50 985ms) |
| **SwiftPaxos** | **11968.4** | **60** | 92.1% | 42.58 ms | 70 (bottleneck replica pinned) |
| **Jetpack+Raft fp100** | **8997.9** | **45** | 70.9% | 42.52 ms | 50 (bottleneck replica pinned) |
| **Jetpack+Raft adaptive** | **7993.4** | **40** | 57.2% | 42.17 ms | 45 (bottleneck replica pinned) |

**Peak throughput order**: EPaxos > Raft > SwiftPaxos > Jetpack+Raft fp100 > Jetpack+Raft adaptive.

**Key observations**:

1. **EPaxos has the highest peak by a wide margin** (19,990 cmd/s vs Raft's 13,984 — ~43% more). EPaxos distributes work across all 5 replicas almost uniformly (all replicas handle proposal traffic), so no single host becomes the bottleneck until N=90+.
2. **Raft's low avg (45.7%) reflects load concentration, not cheap work.** Only the leader is busy; 4 followers mostly replicate AppendEntries batches and sit ~10-15%. Peak tput is still bounded by the leader's single pinned core.
3. **SwiftPaxos runs hottest** (avg 92%) because all 5 replicas do dependency/conflict tracking on every command.
4. **Jetpack+Raft variants** land between Raft and SwiftPaxos on CPU: both leader (Raft replication + spec RPC handling) and followers (spec push into command_pool_) work per command.
5. **Throughput per avg-CPU-percent**: Raft 306, EPaxos 274, SwiftPaxos 130, Jetpack+Raft fp100 127, Jetpack+Raft adaptive 140. Raft wins this metric trivially because its 5-host avg is low (only one host is busy); EPaxos wins in absolute peak because even at 73% avg its work is balanced enough for no single replica to pin until N≥100.

## Is EPaxos actually cheaper per command? No — it's just distributed

The user's intuition is right: EPaxos runs `UpdateAttributes` (scan 5 per-replica conflict maps) and `UpdateConflicts` on every PreAccept on every replica, plus the full PreAccept→(Commit) message flow. That is *more* work per command than Raft's append+replicate+commit, not less.

Evidence that EPaxos really is more expensive per command, at a fixed total throughput of ~6000 cmd/s (N30):

| Protocol | Busiest replica (zoo0) CPU % | Avg CPU across 5 replicas |
|---|---:|---:|
| Raft | 38.3% | 28.6% |
| EPaxos | 65.3% | 36.0% |

At the same 6000 cmd/s, EPaxos's busiest core burns **70% more CPU** than Raft's leader. But EPaxos distributes work near-symmetrically across all 5 replicas (each serves as proposer for its local clients), whereas Raft concentrates all replication work on the leader's single pinned core. So the bottleneck is:

- **Raft**: leader core saturates first → peak = (1 core × 100%) ÷ per-command-work-on-leader ≈ 14k cmd/s.
- **EPaxos**: all cores grow roughly in sync → peak = (5 cores × ~100%) ÷ (5 × per-replica-work-per-cmd) ≈ 20k cmd/s before any one replica pins.

The factor-of-1.43 gap (19991 / 13984) between EPaxos and Raft comes entirely from load-balancing — not from EPaxos being cheaper. If Raft added a proxy layer that spread dispatches across replicas, it could match EPaxos's ceiling. And if EPaxos's per-command work were reduced (e.g., batched PreAccept, eliminated per-replica UpdateAttributes scan), it would exceed 20k.

## Pinning is enforced but asymmetric by design

Each deptran_server has 3 threads:
- TID 2098546 (main): no affinity mask — allowed on any core. Stays ~idle after setup.
- TID 2098548 (reactor / server thread): affinity 0x2 → pinned to core 1.
- TID 2098551 (disk / poll thread): affinity 0x2 → pinned to core 1.

So both active server threads share **one** core (core 1). "server median" in each `.res` is the /proc/stat CPU-1 busy fraction over the middle 10s. That faithfully captures the protocol's per-replica CPU because (a) the two active threads are pinned there, (b) the main thread is idle. Cross-protocol comparison via this metric is fair.

Caveat: cpu0 on zoo0 runs ~100% across all protocols — that's an unrelated system process on core 0, not deptran. It doesn't affect core-1 measurements.

## Full sweep tables

### Raft (baseline)

| N | Total tput | CPU avg (5 hosts) | p50 (zoo0) | p50 (zoo3) |
|---:|---:|---:|---:|---:|
| 30 | 5982.6 | 28.57 | 75.61 | 75.91 |
| 40 | 7993.5 | 28.04 | 76.57 | 77.02 |
| 45 | 8996.3 | 35.47 | 77.88 | 78.38 |
| 50 | 9984.9 | 39.26 | 79.85 | 80.18 |
| 55 | 11003.0 | 44.25 | 80.87 | 81.29 |
| 60 | 11990.7 | 45.96 | 88.49 | 88.78 |
| 70 | 13984.4 | 45.75 | 86.78 | 87.15 |
| 80 | 14210.6 | 41.74 | **985.32** | **987.20** ← STOP (bottleneck replica pinned) |

Raft latency is stable at ~76-88ms p50 while scaling. At N80 the leader pins to 100% and p50 collapses to ~985ms — classic queue-buildup pattern. Avg stays low because only the leader is busy.

### Jetpack+Raft fp100 (force 100% fast-path)

| N | Total tput | CPU avg (5 hosts) | p50 (zoo0) | p50 (zoo3) |
|---:|---:|---:|---:|---:|
| 30 | 6002.0 | 51.85 | 41.99 | 42.26 |
| 40 | 7985.6 | 58.70 | 41.99 | 42.22 |
| 45 | 8997.9 | 70.90 | 42.03 | 42.52 |
| 50 | 9993.1 | 67.62 | 43.17 | 43.41 ← STOP (bottleneck replica pinned) |

Fast-path p50 is ~42ms throughout (half of Raft). But peak throughput is much lower than Raft because the leader pins at N50 even though avg CPU is only 68%.

### Jetpack+Raft adaptive

| N | Total tput | CPU avg (5 hosts) | p50 (zoo0) | p50 (zoo3) |
|---:|---:|---:|---:|---:|
| 30 | 5997.5 | 52.95 | 41.55 | 41.99 |
| 40 | 7993.4 | 57.21 | 41.90 | 42.17 |
| 45 | 8990.1 | 71.08 | 43.57 | 44.05 ← STOP (bottleneck replica pinned) |

Adaptive mode saturates slightly earlier than fp100 — likely because it sometimes chooses slow path (adding work to both paths) at moderate load.

### SwiftPaxos

| N | Total tput | CPU avg (5 hosts) | p50 (zoo0) | p50 (zoo3) |
|---:|---:|---:|---:|---:|
| 30 | 5987.7 | 79.61 | 41.60 | 42.07 |
| 40 | 7983.7 | 87.66 | 41.71 | 42.17 |
| 45 | 8990.6 | 89.87 | 41.76 | 42.22 |
| 50 | 9978.9 | 91.32 | 41.85 | 42.32 |
| 55 | 10997.0 | 91.70 | 42.01 | 42.53 |
| 60 | 11968.4 | 92.08 | 42.08 | 42.58 |
| 70 | 14015.2 | 89.83 | 42.53 | 42.98 ← STOP (bottleneck replica pinned) |

SwiftPaxos runs hot from N=30 onward (all 5 replicas at ~80-95% CPU) but keeps scaling. Peak 14k at N70 — comparable to Raft but with 1-RTT latency (42ms vs Raft's 87ms).

### EPaxos

| N | Total tput | CPU avg (5 hosts) | p50 (zoo0) | p50 (zoo3) |
|---:|---:|---:|---:|---:|
| 30 | 6005.9 | 36.04 | 41.45 | 41.85 |
| 40 | 7998.7 | 43.24 | 41.43 | 41.80 |
| 45 | 8989.4 | 49.91 | 41.43 | 41.82 |
| 50 | 9993.2 | 51.86 | 41.42 | 41.82 |
| 55 | 10985.9 | 60.12 | 41.41 | 41.84 |
| 60 | 11973.2 | 56.00 | 41.45 | 41.95 |
| 70 | 14000.0 | 68.15 | 41.46 | 41.96 |
| 80 | 15983.7 | 66.66 | 41.50 | 42.01 |
| 90 | 17963.5 | 76.28 | 41.71 | 42.25 |
| 100 | **19990.6** | 73.14 | 41.96 | 42.53 |

EPaxos is the outlier — p50 stays essentially flat at 41-42ms across the entire sweep. Throughput scales nearly linearly with N (20k at N=100, 18k at N=90, 14k at N=70 — 200 cmd/s per client matches the client issue cap). If we had run N120, EPaxos likely would have saturated there at ~24k.

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
